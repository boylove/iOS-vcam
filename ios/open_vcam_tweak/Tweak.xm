#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <stdarg.h>

#import "VCamConfig.h"
#import "VCamFrameStore.h"
#import "VCamRTMPSource.h"
#import "VCamLog.h"

// ---------------------------------------------------------------------------
// OpenVCam — mediaserverd camera replacement.
//
// Replicates the closed com.x.vcamera approach byte-for-byte per the deep binary
// reverse (../../VCAMERA_FRAME_REPLACEMENT_DEEP_REVERSE.md): hook the terminal
// BufferWorks node `BWNodeOutput -emitSampleBuffer:` inside mediaserverd and
// OVERWRITE THE CAMERA'S OWN CVImageBuffer IN PLACE with the decoded RTMP frame
// via VTPixelTransferSessionTransferImage, then pass the SAME (now-overwritten)
// sample buffer to the original. In-place overwrite of the shared IOSurface is
// what actually reaches every client's live preview — apps read that upstream
// surface directly, so emitting a fresh downstream buffer never reaches them
// (that was the earlier bug). Using VideoToolbox (not CIContext), on the terminal
// emit only (never the BWPixelTransferNode), is why the original neither lags nor
// crashes stock-Camera recording. Because mediaserverd sits below every app, this
// replaces the camera for all clients, including RootHide-patched apps (TikTok)
// that bypass normal app-level tweak injection.
//
// ONE GPU PASS PER FRAME, NO PIXEL ROTATION. The closed vcamera transfers the raw
// decoded frame straight into the camera buffer with a single
// VTPixelTransferSessionTransferImage and does NOT run a per-frame
// VTPixelRotationSession (dynamic RE, memory openvcam-photomode-original-flow:
// photo mode logs exactly one transfer/frame, src stays 1080x1920). Orientation is
// carried by the pipeline's existing BWVideoOrientationMetadataNode metadata (hooked
// pass-through only), which the system applies at display/encode — no pixel rotation
// is needed. OpenVCam previously added a SECOND GPU pass (rotate into a shared
// intermediate, then transfer); that extra pass on a shared surface is what closed
// the GPU IOSurface fence cycle (bug_type 284 iofence) and froze mediaserverd on the
// stock-Camera video<->photo switch. Removing it — one direct transfer, like the
// original — is the fix.
//
// Still-photo capture needs NO dedicated hook: emitSampleBuffer: overwrites the
// upstream shared IOSurface, and the still-image pipeline downstream reads that same
// already-OBS surface (roadmap M6 "共享面继承"; report §3.10). VCAM_HOOK_PHOTO_NODES
// stays 0.
//
// See memory: vcamera-mediaserverd-hookpoints, openvcam-photomode-original-flow;
// report: VCAMERA_DEB_REVERSE_ANALYSIS.md §3.9-3.10, VCAMERA_DEB_REPLICATION_ROADMAP.md
// M6. Fail-open everywhere; a missing/stale decoded frame -> pure pass-through (never
// a black or frozen frame).
// ---------------------------------------------------------------------------

#define VCAM_LOG_NAME @"OpenVCam.log"
static const NSTimeInterval kVCamFrameMaxAge = 0.5;   // watchdog: 500ms

// Still-photo replacement. DEFAULT OFF (0) — the closest-to-original, device-verified
// stable configuration. Do NOT flip to 1 without re-testing stock-Camera photo mode
// on-device.
//
// WHY OFF: hooking the photo render nodes (BWStillImageScalerNode /
// BWPhotoEncoderNode) and overwriting the still buffer is unnecessary AND historically
// deadlocked the GPU on the video<->photo switch. It is unnecessary because the
// original makes the shutter capture OBS through the SHARED IOSurface — emitSampleBuffer:
// overwrites the camera's upstream buffer, and the still-image pipeline downstream reads
// that same (already-OBS) surface. The original's photo-node hook (modifyPixelBuffer:)
// is a FACE-GATED beauty overlay (`if(!hasFace) pass-through`), not the switch that makes
// the photo be OBS. So with photo=0 the shutter still captures OBS via the shared
// surface. See memory openvcam-photo-path-iofence-deadlock / openvcam-photomode-original-flow
// and EXECUTION-PLAN §4.8.
#ifndef VCAM_HOOK_PHOTO_NODES
#define VCAM_HOOK_PHOTO_NODES 0
#endif

// GPU fence flush after each transfer. DEFAULT OFF (0): device evidence (2026-07-08,
// syslog `AppleM2ScalerCSCDriver: IOFence is hung`) showed that locking the DEST
// surface right after the transfer is what closes the GPU fence cycle in photo mode —
// mediaserverd survives (not killed) but the scaler stays hung and the preview freezes
// on the last OBS frame. The closed vcamera does NOT lock the CVPixelBuffer around its
// transfer (disassembly, memory openvcam-original-gpu-sync-model point 1); it just
// submits the GPU transfer and returns. Match that: no flush. Set -DVCAM_GPU_FENCE_FLUSH=1
// only to A/B test the old behavior.
#ifndef VCAM_GPU_FENCE_FLUSH
#define VCAM_GPU_FENCE_FLUSH 0
#endif

// -- Freeze-hunt diagnostic toggles (2026-07-08). Device-confirmed: even the
// doc-prescribed 0.5.1 config (single transfer, no rotation, no flush) STILL
// wedges the preview after ~24 in-place transfers into the camera's shared
// IOSurface pool (soft GPU/IOSurface fence ring; mediaserverd stays alive, the
// image-bearing emits just stop). These two flags isolate the cause; each build
// logs its state at startup so the syslog proves which variant is running.
//
// VCAM_DEST_COLOR (default 0): set the transfer session's DESTINATION colour
// properties (ITU-R 709 primaries/transfer, 601 matrix) — the one concrete
// session-config difference the closed vcamera has that we lack (ANALYSIS §3.5).
// If a colour-path mismatch is what makes VT pick a fence-conflicting scaler
// path, pinning the destination colour should stop the wedge.
#ifndef VCAM_DEST_COLOR
#define VCAM_DEST_COLOR 0
#endif

// VCAM_GPU_ACCEL (default 1 = on, matching the closed vcamera). Set 0 to force
// the CPU transfer path (EnableGPUAcceleratedTransfer=false). The wedge is a GPU
// fence; if the CPU path does not wedge, that proves the GPU-accelerated transfer
// into the live camera surface is the culprit and points the real fix.
#ifndef VCAM_GPU_ACCEL
#define VCAM_GPU_ACCEL 1
#endif

// AVCaptureDevicePosition: 0 unspecified, 1 back, 2 front. Updated from the
// FigCaptureSourceConfiguration -sourcePosition hook; recorded for diagnostics (the
// original hooks this too, report §3.8). No longer drives pixel mirroring — front-camera
// mirror was a VTPixelRotationSession flip, removed with the rest of the per-frame
// rotation pass; the front camera now shows OBS un-mirrored.
static volatile long gSourcePosition = 0;

// ---------------------------------------------------------------------------
// Stall watchdog / heartbeat (diagnostic for the "moves once then freezes" bug).
//
// The health line is printed FROM INSIDE the emit hook — so if the capture
// thread ever blocks inside our replacement (e.g. wedged in the photo path on a
// photo<->video transition, the historic mediaserverd hang), that log line never
// fires again and the freeze looks identical to "idle". This heartbeat runs on
// its OWN thread and reports the emit counter from the outside, so a hang shows
// up as "emits STALLED at N" with the in-flight breakdown pinpointing WHERE the
// thread is stuck: photoInflight>0 => blocked in VCamPhotoRender (photo path);
// emitInflight>0 with photoInflight==0 => blocked in the live-video overwrite.
// Pure observer, no locks touched — safe to leave on in release builds.
static volatile uint64_t gEmitEntries  = 0;   // VCamEmit entered
static volatile uint64_t gEmitReturns  = 0;   // VCamEmit's orig() returned
static volatile uint64_t gPhotoEntries = 0;   // VCamPhotoRender entered
static volatile uint64_t gPhotoReturns = 0;   // VCamPhotoRender's orig() returned

static void VCamStartHeartbeat(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            uint64_t last = 0;
            BOOL stalledLogged = NO;
            for (;;) {
                sleep(2);
                uint64_t now         = gEmitEntries;
                uint64_t emitInflight  = gEmitEntries  - gEmitReturns;
                uint64_t photoInflight = gPhotoEntries - gPhotoReturns;
                if (now != last) {                 // frames still flowing -> healthy
                    last = now;
                    stalledLogged = NO;
                } else if (now > 0 && !stalledLogged) {
                    // Counter was advancing and has now been frozen for ~2s: the
                    // capture thread is blocked, not merely idle (idle still emits
                    // real-camera frames, so the counter keeps rising). Report where.
                    stalledLogged = YES;
                    VCamLog(@"HEARTBEAT: emits STALLED at %llu (emitInflight=%llu photoInflight=%llu) "
                            "-> mediaserverd capture thread BLOCKED%@",
                            now, emitInflight, photoInflight,
                            photoInflight > 0 ? @" IN PHOTO PATH (VCAM_HOOK_PHOTO_NODES)"
                                              : (emitInflight > 0 ? @" IN LIVE OVERWRITE" : @""));
                }
            }
        });
    });
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------
static NSString *VCamLogPath(void) {
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length > 0) return [tmp stringByAppendingPathComponent:VCAM_LOG_NAME];
    return [@"/tmp" stringByAppendingPathComponent:VCAM_LOG_NAME];
}

void VCamLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[OpenVCam] %@", message);

    @try {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSString *path = VCamLogPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            [data writeToFile:path atomically:NO];
        } else {
            NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
            if (h) { [h seekToEndOfFile]; [h writeData:data]; [h closeFile]; }
        }
    } @catch (__unused NSException *e) { /* sandbox may deny file writes */ }
}

// ---------------------------------------------------------------------------
// VideoToolbox pixel-transfer session.
//
// The closed vcamera converts the decoded RTMP frame into a camera-format buffer
// with VTPixelTransferSession (scale + pixel-format / colour-range conversion),
// NOT CoreImage. CIContext rendering a decoded frame into a biplanar YCbCr
// (420v/420f) buffer with a NULL colour space came out BLACK downstream;
// VTPixelTransferSession does the YCbCr<->YCbCr and video<->full-range
// conversion correctly. The session adapts to the src/dst buffers on each call,
// so we create it once and reuse it, serialised by gVTLock because the capture
// graph can service several source nodes concurrently. This is the ONLY GPU pass
// per frame — no VTPixelRotationSession; orientation is left to the pipeline's
// existing metadata (see the header note).
// ---------------------------------------------------------------------------
static VTPixelTransferSessionRef gTransferSession;
static NSLock *gVTLock;

static void VCamEnsureSessions(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gVTLock = [[NSLock alloc] init];
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &gTransferSession);
        if (gTransferSession) {
            // CRITICAL: without a scaling mode, VTPixelTransferSessionTransferImage
            // FAILS whenever the source (decoded RTMP frame, e.g. 1080x1920) and the
            // destination (camera buffer, a different size) differ — which is the
            // normal case. That silent failure => replacement NULL => real camera.
            // Trim = scale preserving aspect ratio, cropping overflow — matches the
            // closed vcamera (it sets kVTScalingMode_Trim, RE'd at 0x84928). Trim
            // avoids the stretched look Normal gives when src/dst aspect ratios differ.
            VTSessionSetProperty(gTransferSession, kVTPixelTransferPropertyKey_ScalingMode,
                                 kVTScalingMode_Trim);
            // GPU-accelerated transfer, matching the closed vcamera's session config
            // (analysis §3.5 / memory openvcam-original-gpu-sync-model: it sets
            // EnableGPUAcceleratedTransfer=kCFBooleanTrue at 0x82470–0x8267c). No
            // public VT constant exists for this key, so it is set by its string name
            // (the same way the original does). The scaler/CSC work runs on the GPU
            // (AppleM2ScalerCSC); leaving this unset let VT pick a path whose fence
            // interaction with photo mode's own still-scaler differed from the original.
            // VCAM_GPU_ACCEL=0 forces the CPU path to test whether the GPU fence ring
            // is what wedges the preview after ~24 in-place transfers.
            VTSessionSetProperty(gTransferSession,
                                 (__bridge CFStringRef)@"EnableGPUAcceleratedTransfer",
                                 VCAM_GPU_ACCEL ? kCFBooleanTrue : kCFBooleanFalse);

#if VCAM_DEST_COLOR
            // Pin the DESTINATION colour the same way the closed vcamera does
            // (ANALYSIS §3.5: 709 primaries/transfer, 601 matrix). Without this VT
            // infers the destination colour, which can push it onto a different
            // scaler/CSC path than the original — a candidate cause of the fence wedge.
            VTSessionSetProperty(gTransferSession,
                                 kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                                 kCVImageBufferColorPrimaries_ITU_R_709_2);
            VTSessionSetProperty(gTransferSession,
                                 kVTPixelTransferPropertyKey_DestinationTransferFunction,
                                 kCVImageBufferTransferFunction_ITU_R_709_2);
            VTSessionSetProperty(gTransferSession,
                                 kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                                 kCVImageBufferYCbCrMatrix_ITU_R_601_4);
#endif
        }
    });
}

// Always-on failure-reason counters so the periodic health line reports WHY an
// overwrite was skipped (fail-open): no fresh decoded frame, no transfer session,
// or the VT transfer failed. Read in the health line; that is the reliable
// diagnostic (startup-gated debug logs fire before a syslog capture can attach).
static uint64_t gRNoFresh, gRNoXfer, gRXferFail;

// Overwrites the camera's OWN CVImageBuffer IN PLACE with the decoded RTMP frame,
// exactly like the closed vcamera's -[<core> modifyImageBuffer:]
// (see ../../VCAMERA_FRAME_REPLACEMENT_DEEP_REVERSE.md §2.2): it calls
// VTPixelTransferSessionTransferImage(session, OBS frame, CAMERA image buffer),
// writing straight into the camera's shared IOSurface. THAT is what actually
// reaches the app's live preview — apps read that shared surface directly, so
// substituting a new sample buffer downstream does not reach them. Using VT (not
// CIContext), on the terminal emit only (not the PixelTransfer node), is why the
// original neither crashes stock-Camera recording nor lags. Returns YES on
// overwrite; on any failure returns NO and the caller passes the real frame.
static BOOL VCamOverwriteInPlace(CVImageBufferRef cameraBuf) {
    if (!cameraBuf) return NO;
    VCamConfig *cfg = [VCamConfig shared];
    if (!cfg.enabled) return NO;

    CVPixelBufferRef fresh = [[VCamFrameStore shared] copyFreshFrameWithMaxAge:kVCamFrameMaxAge];
    if (!fresh) { gRNoFresh++; return NO; }             // stale/no stream -> real camera

    VCamEnsureSessions();
    if (!gTransferSession) { gRNoXfer++; CVPixelBufferRelease(fresh); return NO; }

    // One-time geometry diagnostic: log the first few distinct destination sizes
    // seen (each client hands us a different buffer), so orientation can be judged
    // from src/dst dims + which physical camera without guessing.
    {
        static long loggedDst[6]; static int nLogged = 0;
        long key = (long)CVPixelBufferGetWidth(cameraBuf) * 100000 + (long)CVPixelBufferGetHeight(cameraBuf);
        BOOL seen = NO;
        for (int i = 0; i < nLogged; i++) if (loggedDst[i] == key) { seen = YES; break; }
        if (!seen && nLogged < 6) {
            loggedDst[nLogged++] = key;
            VCamLog(@"geom: src=%zux%zu dst=%zux%zu front=%d",
                    CVPixelBufferGetWidth(fresh), CVPixelBufferGetHeight(fresh),
                    CVPixelBufferGetWidth(cameraBuf), CVPixelBufferGetHeight(cameraBuf),
                    (gSourcePosition == 2));
        }
    }

    // ONE GPU pass, under gVTLock — exactly like the closed vcamera's photo-mode
    // flow (dynamic RE openvcam-photomode-original-flow: one transfer/frame, src stays
    // raw, no VTPixelRotationSession). Transfer the raw OBS frame straight into the
    // camera's shared IOSurface; the pipeline's existing BWVideoOrientationMetadataNode
    // metadata rotates it at display/encode. An earlier build added a SECOND GPU pass
    // (rotate into a shared intermediate) — that extra pass on a shared surface is what
    // closed the GPU IOSurface fence cycle (bug_type 284 iofence) and froze
    // mediaserverd on the video<->photo switch. Serialise all our submits on this
    // surface with the single lock. ScalingMode=Trim (set on the session) aspect-fills.
    size_t srcW = CVPixelBufferGetWidth(fresh), srcH = CVPixelBufferGetHeight(fresh);
    [gVTLock lock];
    OSStatus ts = VTPixelTransferSessionTransferImage(gTransferSession, fresh, cameraBuf);
#if VCAM_GPU_FENCE_FLUSH
    // OFF by default — device-confirmed to CAUSE the photo-mode AppleM2ScalerCSC
    // IOFence hang (see the macro note). The original does not lock; kept only as an
    // A/B toggle. When on: lock the DEST surface to force the async GPU write to land.
    if (ts == noErr) {
        CVPixelBufferLockBaseAddress(cameraBuf, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(cameraBuf, kCVPixelBufferLock_ReadOnly);
    }
#endif
    [gVTLock unlock];

    CVPixelBufferRelease(fresh);
    if (ts != noErr) {
        gRXferFail++;
        static BOOL logged = NO;
        if (!logged) { logged = YES; VCamLog(@"transfer failed (%d) src=%zux%zu dst=%zux%zu",
                                              (int)ts, srcW, srcH,
                                              CVPixelBufferGetWidth(cameraBuf), CVPixelBufferGetHeight(cameraBuf)); }
        return NO;
    }
    return YES;
}

// ---------------------------------------------------------------------------
// Photo / still-capture path — OPT-IN ONLY (VCAM_HOOK_PHOTO_NODES, default 0).
//
// This is NOT needed for the shutter to capture OBS: emitSampleBuffer: overwrites
// the upstream shared IOSurface and the still pipeline reads that same already-OBS
// surface (roadmap M6 "共享面继承"). Kept behind the compile flag only as an opt-in
// experiment. When enabled, it overwrites the still buffer with a SINGLE direct
// transfer (no per-frame pixel rotation — the same one-pass model as the live path;
// the old two-pass rotate+transfer is what IOFence-deadlocked on the mode switch)
// and dedups with the REAL kCMSampleBufferAttachmentKey_TransitionID so the one
// buffer flowing scaler->encoder->preview/thumbnail is overwritten once, and system
// transition buffers are left alone. Fail-open everywhere: any miss -> the real still.
// ---------------------------------------------------------------------------
// Counters stay unconditionally compiled: the always-on health line reads them so
// the syslog shows photo[...] = 0 when the photo path is disabled (the default).
static uint64_t gRPhotoNoFresh, gRPhotoDup, gRPhotoXferFail, gPhotoReplaced;

#if VCAM_HOOK_PHOTO_NODES
static VTPixelTransferSessionRef gPhotoTransferSession;
static NSLock *gPhotoVTLock;

static void VCamEnsurePhotoSession(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gPhotoVTLock = [[NSLock alloc] init];
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &gPhotoTransferSession);
        if (gPhotoTransferSession) {
            // Same reason as the video session: without a scaling mode the transfer
            // FAILS whenever the still buffer's size differs from the decoded frame.
            // Trim matches the closed vcamera (kVTScalingMode_Trim).
            VTSessionSetProperty(gPhotoTransferSession, kVTPixelTransferPropertyKey_ScalingMode,
                                 kVTScalingMode_Trim);
        }
    });
}

static BOOL VCamOverwritePhotoInPlace(CMSampleBufferRef sb) {
    if (!sb) return NO;
    VCamConfig *cfg = [VCamConfig shared];
    if (!cfg.enabled) return NO;

    // Dedup with the REAL TransitionID (report §2.3). Two jobs: (1) a still flows
    // scaler->encoder->preview/thumbnail, so the first node stamps it and the rest
    // skip — overwrite exactly once; (2) the system stamps TransitionID on the
    // buffers it shuffles during a photo<->video mode switch, so seeing it here
    // means "leave this one alone", which keeps us out of the transition that used
    // to hang mediaserverd. Propagating mode carries the mark onto derived buffers.
    if (CMGetAttachment(sb, kCMSampleBufferAttachmentKey_TransitionID, NULL) != NULL) {
        gRPhotoDup++;
        return YES;   // already ours, or a system transition buffer -> pass through
    }

    CVImageBufferRef dst = CMSampleBufferGetImageBuffer(sb);
    if (!dst) return NO;

    CVPixelBufferRef fresh = [[VCamFrameStore shared] copyFreshFrameWithMaxAge:kVCamFrameMaxAge];
    if (!fresh) { gRPhotoNoFresh++; return NO; }        // stale/no stream -> real still

    VCamEnsurePhotoSession();
    if (!gPhotoTransferSession) { CVPixelBufferRelease(fresh); return NO; }

    // ONE GPU pass under gPhotoVTLock, no per-frame pixel rotation — same model as
    // the live path (see VCamOverwriteInPlace): transfer the raw OBS frame straight
    // into the still buffer; orientation is carried by the pipeline's existing
    // metadata. The old two-pass (rotate then transfer) is what IOFence-deadlocked
    // on the photo-mode switch. NOTE: this whole path is compiled OUT by default
    // (VCAM_HOOK_PHOTO_NODES=0) because the shared-IOSurface inheritance from the
    // emit hook already makes the shutter capture OBS; kept only as an opt-in.
    [gPhotoVTLock lock];
    OSStatus ts = VTPixelTransferSessionTransferImage(gPhotoTransferSession, fresh, dst);
#if VCAM_GPU_FENCE_FLUSH
    // Force GPU completion of the still write before returning (same flush as the
    // live path — see VCamOverwriteInPlace).
    if (ts == noErr) {
        CVPixelBufferLockBaseAddress(dst, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(dst, kCVPixelBufferLock_ReadOnly);
    }
#endif
    [gPhotoVTLock unlock];

    CVPixelBufferRelease(fresh);
    if (ts != noErr) {
        gRPhotoXferFail++;
        static BOOL logged = NO;
        if (!logged) { logged = YES; VCamLog(@"photo transfer failed (%d)", (int)ts); }
        return NO;
    }

    // Stamp the real TransitionID so downstream photo nodes skip re-overwriting
    // this (or a derived) buffer — matching the original.
    CMSetAttachment(sb, kCMSampleBufferAttachmentKey_TransitionID, (__bridge CFTypeRef)@(1),
                    kCMAttachmentMode_ShouldPropagate);
    gPhotoReplaced++;
    return YES;
}
#endif  // VCAM_HOOK_PHOTO_NODES

// ---------------------------------------------------------------------------
// Hook plumbing for private mediaserverd classes (objc_getClass + MSHookMessageEx)
// ---------------------------------------------------------------------------
static NSMutableDictionary<NSValue *, NSValue *> *gEmitOrigs;    // Class -> IMP
static NSMutableDictionary<NSValue *, NSValue *> *gRenderOrigs;  // photo nodes -> IMP

static IMP VCamFindOrig(NSMutableDictionary<NSValue *, NSValue *> *map, id obj) {
    Class c = object_getClass(obj);
    while (c) {
        NSValue *v = map[[NSValue valueWithPointer:(__bridge void *)c]];
        if (v) return (IMP)[v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

// -[BWNodeOutput emitSampleBuffer:] — overwrite the camera's image buffer IN
// PLACE (exactly like vcamera's -[<core> modifyImageBuffer:]), then call the
// original with the ORIGINAL sample buffer. This is the ONLY node the original
// modifies; the render nodes are left untouched (see the deep reverse report).
static void VCamEmit(id self, SEL _cmd, CMSampleBufferRef sb) {
    IMP orig = VCamFindOrig(gEmitOrigs, self);
    if (!orig) return;
    gEmitEntries++;                            // heartbeat: entered (before any work)
    [[VCamRTMPSource shared] ensureStarted];   // idempotent; keeps the RTMP puller alive
    CVImageBufferRef ib = sb ? CMSampleBufferGetImageBuffer(sb) : NULL;
    BOOL did = ib ? VCamOverwriteInPlace(ib) : NO;
    ((void (*)(id, SEL, CMSampleBufferRef))orig)(self, _cmd, sb);   // original sb, now overwritten
    gEmitReturns++;                            // heartbeat: orig returned (emit not blocked)

    // Always-on health line: distinguishes "OBS not showing" (replaced=0) from
    // "decoder idle / fail-open" via syslog; the why[] counters pinpoint the cause.
    static uint64_t calls = 0, repl = 0;
    calls++;
    if (did) { repl++; if (repl == 1) VCamLog(@"health: first frame replaced (OBS is live)"); }
    if ((calls % 600) == 0)
        VCamLog(@"health: emits=%llu replaced=%llu why[noFresh=%llu noXfer=%llu xferFail=%llu] "
                "photo[replaced=%llu noFresh=%llu dup=%llu xferFail=%llu]",
                calls, repl, gRNoFresh, gRNoXfer, gRXferFail,
                gPhotoReplaced, gRPhotoNoFresh, gRPhotoDup, gRPhotoXferFail);
}

// -[<photo node> renderSampleBuffer:forInput:] — the still-capture nodes
// (BWStillImageScalerNode, BWPhotoEncoderNode). Overwrite the still buffer IN
// PLACE with the OBS frame, then call the original so the encoder/preview/
// thumbnail still run on our pixels. The TransitionID dedup inside
// VCamOverwritePhotoInPlace means only the first node in the chain does the
// transfer; the rest see the tag and pass through. forInput: is opaque here
// (BWNodeInput*), so it is threaded straight to the original untouched.
#if VCAM_HOOK_PHOTO_NODES
static void VCamPhotoRender(id self, SEL _cmd, CMSampleBufferRef sb, id input) {
    IMP orig = VCamFindOrig(gRenderOrigs, self);
    if (!orig) return;
    gPhotoEntries++;                           // heartbeat: entered photo hook
    if (sb) VCamOverwritePhotoInPlace(sb);
    ((void (*)(id, SEL, CMSampleBufferRef, id))orig)(self, _cmd, sb, input);
    gPhotoReturns++;                           // heartbeat: photo hook returned
}
#endif

// -[FigCaptureSourceConfiguration sourcePosition] — records which physical
// camera is active (front/back) so the overwrite path can auto-mirror the front
// camera. Pure observer: always returns the original value, never fails the call.
static long (*gSourcePositionOrig)(id, SEL) = NULL;
static long VCamSourcePosition(id self, SEL _cmd) {
    long pos = gSourcePositionOrig ? gSourcePositionOrig(self, _cmd) : 0;
    gSourcePosition = pos;
    return pos;
}

static void VCamHookSourcePosition(void) {
    Class c = objc_getClass("FigCaptureSourceConfiguration");
    SEL sel = @selector(sourcePosition);
    if (!c || !class_getInstanceMethod(c, sel)) {
        VCamLog(@"sourcePosition hook unavailable; front auto-mirror off");
        return;
    }
    MSHookMessageEx(c, sel, (IMP)VCamSourcePosition, (IMP *)&gSourcePositionOrig);
    if (gSourcePositionOrig) VCamLog(@"hooked FigCaptureSourceConfiguration sourcePosition");
}

static void VCamHook(const char *clsName, SEL sel, IMP repl,
                     NSMutableDictionary<NSValue *, NSValue *> *origMap) {
    Class c = objc_getClass(clsName);
    if (!c) { VCamLog(@"class %s not found", clsName); return; }
    if (!class_getInstanceMethod(c, sel)) {
        VCamLog(@"%s has no %@", clsName, NSStringFromSelector(sel));
        return;
    }
    IMP orig = NULL;
    MSHookMessageEx(c, sel, repl, &orig);
    if (orig) {
        origMap[[NSValue valueWithPointer:(__bridge void *)c]] =
            [NSValue valueWithPointer:(const void *)orig];
        VCamLog(@"hooked %s %@", clsName, NSStringFromSelector(sel));
    }
}

%ctor {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"";
        if (![proc isEqualToString:@"mediaserverd"]) return;   // safety: mediaserverd only

        gEmitOrigs = [NSMutableDictionary dictionary];

        VCamConfig *cfg = [VCamConfig shared];
        VCamLog(@"loading in mediaserverd, enabled=%d url=%@", cfg.enabled, cfg.rtmpURL);

        // Hook ONLY the terminal BWNodeOutput emitSampleBuffer:. Per the binary
        // analysis of the closed vcamera (VCAMERA_FRAME_REPLACEMENT_DEEP_REVERSE.md),
        // that is the single place it modifies the frame: it overwrites the camera's
        // own image buffer IN PLACE there (via VTPixelTransfer), and passes the same
        // sample buffer on. Modifying the shared IOSurface is what reaches the app's
        // live preview. vcamera hooks the render nodes too but only as pass-through,
        // so we don't hook them at all — which also avoids the BWPixelTransferNode
        // recording-crash path entirely.
        VCamHook("BWNodeOutput", @selector(emitSampleBuffer:), (IMP)VCamEmit, gEmitOrigs);

        // Still-capture path (report §1.1/§2.3). The live-video emit hook above
        // only covers the streaming preview; a still photo flows through the photo
        // nodes instead, so without these the shutter captures the REAL lens. We
        // overwrite the still buffer IN PLACE at these nodes with TransitionID
        // dedup (VCamOverwritePhotoInPlace) — the same nodes and technique the
        // closed vcamera uses. These are the photo scaler/encoder nodes, NOT the
        // live-video render nodes the report warns crash recording when overwritten
        // (BWNode/BWUBNode/BWPixelTransferNode) — those we still never touch.
        // Compile-time escape hatch: -DVCAM_HOOK_PHOTO_NODES=0 disables the still
        // path entirely (shutter falls back to the real lens) if it ever misbehaves
        // on the stock Camera, without affecting live streaming.
#if VCAM_HOOK_PHOTO_NODES
        gRenderOrigs = [NSMutableDictionary dictionary];
        SEL renderSel = @selector(renderSampleBuffer:forInput:);
        VCamHook("BWStillImageScalerNode", renderSel, (IMP)VCamPhotoRender, gRenderOrigs);
        VCamHook("BWPhotoEncoderNode",     renderSel, (IMP)VCamPhotoRender, gRenderOrigs);
#endif

        // Front/back detection for auto-mirror (config files unreadable here).
        VCamHookSourcePosition();

        // Start the stall watchdog BEFORE frames flow: it reports from its own
        // thread if the capture thread ever wedges inside our hooks, so the
        // "moves once then freezes" symptom shows up as "emits STALLED" with an
        // in-flight breakdown (photo path vs live overwrite) instead of silence.
        VCamStartHeartbeat();

        // Start pulling immediately; frames only get used once enabled + fresh.
        [[VCamRTMPSource shared] ensureStarted];
        // Log the photo-node compile state so the syslog itself proves WHICH build
        // is running (photo=1 default vs the -DVCAM_HOOK_PHOTO_NODES=0 diagnostic
        // build) — avoids "fixed it" false positives from flashing the wrong deb.
        VCamLog(@"hooks installed (%lu emit, %lu photo) VCAM_HOOK_PHOTO_NODES=%d "
                "DEST_COLOR=%d GPU_ACCEL=%d FENCE_FLUSH=%d",
                (unsigned long)gEmitOrigs.count, (unsigned long)gRenderOrigs.count,
                VCAM_HOOK_PHOTO_NODES, VCAM_DEST_COLOR, VCAM_GPU_ACCEL, VCAM_GPU_FENCE_FLUSH);
    }
}

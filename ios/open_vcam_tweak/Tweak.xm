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
// VCAM_DEST_COLOR (default 1 = ON, matching the closed vcamera). Sets the transfer
// session's DESTINATION colour (ITU-R 709 primaries/transfer, 601 matrix), exactly
// what the original sets on all three of its transfer sessions (RE 0x82494-0x82504).
// Without it VT infers the destination colour, which comes out WRONG for the
// still-capture buffer — the "photo colour is off after shutter" symptom. On by
// default now that dedup (not colour) is confirmed as the freeze fix.
#ifndef VCAM_DEST_COLOR
#define VCAM_DEST_COLOR 1
#endif

// Orientation. The closed vcamera creates a VTPixelRotationSession(kVTRotation_CCW90)
// (RE 0x82638-0x8267c) and rotates the decoded OBS frame so it lines up with the
// camera buffer; the freeze-hunt stripped this out (0.5.0), which is why the preview
// is 90° off. Restored now that dedup — not the rotation pass — is the confirmed
// freeze fix; the rotation runs ONCE per buffer (inside the dedup) into a reused
// buffer under gVTLock, matching the original's single-lock discipline.
//   VCAM_AUTO_ORIENT: pick 0° vs a quarter-turn by comparing OBS vs camera aspect
//     (portrait TikTok preview needs 0°, landscape stock-Camera buffer needs a turn).
//   VCAM_AUTO_ORIENT_DIR: which quarter-turn (270 = CCW90, matching the original).
//   VCAM_FRONT_AUTOMIRROR: horizontally mirror the front camera (original does too).
#ifndef VCAM_AUTO_ORIENT
#define VCAM_AUTO_ORIENT 1
#endif
#ifndef VCAM_AUTO_ORIENT_DIR
#define VCAM_AUTO_ORIENT_DIR 270
#endif
#ifndef VCAM_FRONT_AUTOMIRROR
#define VCAM_FRONT_AUTOMIRROR 1
#endif

// VCAM_GPU_ACCEL (default 1 = on, matching the closed vcamera). Set 0 to force
// the CPU transfer path (EnableGPUAcceleratedTransfer=false). The wedge is a GPU
// fence; if the CPU path does not wedge, that proves the GPU-accelerated transfer
// into the live camera surface is the culprit and points the real fix.
#ifndef VCAM_GPU_ACCEL
#define VCAM_GPU_ACCEL 1
#endif

// VCAM_VIDEO_DEDUP (default 1 = ON, matching the closed vcamera). THE FREEZE FIX
// (instruction-level RE of the original's -[<core> modifyImageBuffer:] at 0x8432c):
// the original overwrites each sample buffer EXACTLY ONCE, deduped by
// kCMSampleBufferAttachmentKey_TransitionID with kCMAttachmentMode_ShouldPropagate —
// CMGetAttachment; if present -> skip; else transfer, then CMSetAttachment(...,@1,
// ShouldPropagate). The camera graph re-emits the SAME buffer through many outputs
// (~930 emits/s vs ~90 real frames/s on this device), so WITHOUT this dedup we ran
// VTPixelTransferSessionTransferImage ~10x per frame into the shared camera IOSurface,
// piling up GPU writes until the scaler's IOSurface fence ring wedged the preview
// (device-confirmed: froze at a VARIABLE frame count — 24/210/249 — independent of
// session config, which we proved is byte-identical to the original). Deduping cuts us
// to one transfer per buffer like the original, which does the same in-place overwrite
// on this exact device without freezing. Set 0 only to A/B the old every-emit behavior.
// DEFAULT 0 (matching the original): instruction-level RE of the original's video
// -[<core> modifyImageBuffer:] @0x84458 shows it does NO dedup — no CMGetAttachment,
// no TransitionID, exactly ONE VTPixelTransferSessionTransferImage per call, an
// unconditional in-place overwrite every emit. Our private-key dedup (VCamDedupKey +
// ShouldPropagate) was device-confirmed to CAUSE the sharp<->blur cycling: the camera
// pool RECYCLES buffers, so a surface we stamped gets reused for a fresh REAL-camera
// frame with our key still attached -> we see the key, skip the overwrite, and that
// real (blurry) frame shows through, alternating ~47% of emits with OBS (health line:
// dup~=replaced). The original proves per-frame overwrite does not freeze on this
// device; the old "24-frame freeze" was fixed by the single-lock session model, not by
// dedup. Set 1 only to A/B the old buggy behavior.
#ifndef VCAM_VIDEO_DEDUP
#define VCAM_VIDEO_DEDUP 0
#endif

// VCAM_PRIVATE_DEDUP_KEY (default 1 = ON). The dedup above (0.5.4/0.5.5) keyed on
// the SYSTEM's kCMSampleBufferAttachmentKey_TransitionID: present -> skip. That fixed
// the freeze but had a side effect on the stock-Camera photo<->video mode switch —
// the capture stack stamps TransitionID on the buffers it shuffles during the switch,
// so our hook saw it "already present" and passed those through as the REAL (blurry)
// lens, ALTERNATING with the buffers we did overwrite (sharp OBS) => the sharp/blur
// cycling reported on the mode switch. Fix: dedup on our OWN private key instead.
// Re-emits of a buffer we stamped still carry the key (ShouldPropagate), so they are
// still skipped — the freeze fix is intact — but system transition buffers do NOT
// carry it, so we overwrite them too and the switch stays sharp OBS. Set 0 to fall
// back to the old shared-TransitionID behavior for A/B.
#ifndef VCAM_PRIVATE_DEDUP_KEY
#define VCAM_PRIVATE_DEDUP_KEY 1
#endif

// VCAM_DEST_MATRIX_709 (default 0 = 601, matching the closed vcamera). Selects the
// transfer session's DESTINATION YCbCr matrix AND the matrix tag we stamp on the
// output — kept together (VCamDestMatrix) so the chroma we WRITE and the tag we
// ADVERTISE always agree. The saved photo shifting red is a YCbCr->RGB matrix
// mismatch: the still JPEG encoder converts our transferred pixels using a matrix,
// and if it reads the camera buffer's native 709 while we wrote 601 chroma, reds
// blow out. Flip to 1 to A/B whether writing+tagging 709 (matching the camera's
// native still format) fixes the photo colour without hooking the encoder nodes.
#ifndef VCAM_DEST_MATRIX_709
#define VCAM_DEST_MATRIX_709 0
#endif

// --- Colour helpers, shared by the video and photo transfer paths ---------------
// The destination YCbCr matrix used by the transfer sessions, in ONE place so the
// pixels written and the tag stamped never diverge (see VCAM_DEST_MATRIX_709).
static CFStringRef VCamDestMatrix(void) {
#if VCAM_DEST_MATRIX_709
    return kCVImageBufferYCbCrMatrix_ITU_R_709_2;
#else
    return kCVImageBufferYCbCrMatrix_ITU_R_601_4;
#endif
}

// Stamp the colour tags on a destination buffer with ShouldPropagate so downstream
// consumers — crucially the still-image JPEG encoder — interpret our transferred OBS
// pixels with the SAME matrix we wrote them in. The closed vcamera stamps these too
// (RE 0x90110-0x90174). Missing/mismatched here is the "saved photo goes red" symptom.
static void VCamStampColour(CVBufferRef buf) {
    CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey,
                          VCamDestMatrix(), kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
}

// The attachment key our dedup keys on. Private key (default) so we only skip buffers
// WE stamped, not the system's mode-switch transition buffers (see VCAM_PRIVATE_DEDUP_KEY).
// Marked unused: only referenced when VCAM_VIDEO_DEDUP=1 (now default 0), so the Theos
// release -Werror,-Wunused-function must not fail the build when dedup is compiled out.
__attribute__((unused))
static CFStringRef VCamDedupKey(void) {
#if VCAM_PRIVATE_DEDUP_KEY
    return CFSTR("OpenVCamOverwritten");
#else
    return kCMSampleBufferAttachmentKey_TransitionID;
#endif
}

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
                                 VCamDestMatrix());
#endif
        }
    });
}

// Always-on failure-reason counters so the periodic health line reports WHY an
// overwrite was skipped (fail-open): no fresh decoded frame, no transfer session,
// or the VT transfer failed. Read in the health line; that is the reliable
// diagnostic (startup-gated debug logs fire before a syslog capture can attach).
static uint64_t gRNoFresh, gRNoXfer, gRXferFail, gRDup;

// ---------------------------------------------------------------------------
// Rotation / front-camera mirror (VTPixelRotationSession), matching the closed
// vcamera's _pixelRotationSession. The decoded OBS frame is rotated into ONE reused
// buffer (never a fresh buffer per frame) inside gVTLock, then the transfer session
// scales/converts it into the camera surface. Reusing the buffer + single lock is
// the original's discipline; combined with the video dedup this runs once per buffer.
// ---------------------------------------------------------------------------
typedef struct { CVPixelBufferRef buf; size_t w, h; OSType fmt; } VCamRotBuf;
static VCamRotBuf gRotBuf;
static CFTypeRef gRotationSession;   // VTPixelRotationSessionRef, or NULL

// Cached rotation-output buffer; (re)allocated only when geometry changes. The SAME
// buffer is returned every call (cache-owned; caller must NOT release). Caller MUST
// hold gVTLock.
static CVPixelBufferRef VCamRotBufGet(VCamRotBuf *p, size_t w, size_t h, OSType fmt) {
    if (!p->buf || p->w != w || p->h != h || p->fmt != fmt) {
        if (p->buf) { CVPixelBufferRelease(p->buf); p->buf = NULL; }
        NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
        CVPixelBufferRef nb = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt,
                                (__bridge CFDictionaryRef)attrs, &nb) == kCVReturnSuccess) {
            p->buf = nb; p->w = w; p->h = h; p->fmt = fmt;
        }
    }
    return p->buf;
}

// Rotate `fresh` into the cached buffer and return it (cache-owned, NOT retained).
// Returns NULL when no rotation/mirror is needed (caller transfers `fresh` directly)
// or on failure. Caller MUST already hold gVTLock so rotate+transfer is one
// uninterrupted critical section (the original holds a single lock across both).
static CVPixelBufferRef VCamCopyRotatedLocked(CVPixelBufferRef fresh, BOOL mirror, long rot) {
    if (!mirror && rot == 0) return NULL;
    CVPixelBufferRef rotated = NULL;
    if (@available(iOS 16.0, *)) {
        if (!gRotationSession) {
            VTPixelRotationSessionRef rs = NULL;
            VTPixelRotationSessionCreate(kCFAllocatorDefault, &rs);
            gRotationSession = rs;
        }
        VTPixelRotationSessionRef rs = (VTPixelRotationSessionRef)gRotationSession;
        if (rs) {
            CFStringRef rotKey = kVTRotation_0;
            if (rot == 90) rotKey = kVTRotation_CW90;
            else if (rot == 180) rotKey = kVTRotation_180;
            else if (rot == 270) rotKey = kVTRotation_CCW90;
            VTSessionSetProperty(rs, kVTPixelRotationPropertyKey_Rotation, rotKey);
            VTSessionSetProperty(rs, kVTPixelRotationPropertyKey_FlipHorizontalOrientation,
                                 mirror ? kCFBooleanTrue : kCFBooleanFalse);
            size_t fw = CVPixelBufferGetWidth(fresh), fh = CVPixelBufferGetHeight(fresh);
            OSType ffmt = CVPixelBufferGetPixelFormatType(fresh);
            size_t rw = (rot == 90 || rot == 270) ? fh : fw;   // a quarter turn swaps W/H
            size_t rh = (rot == 90 || rot == 270) ? fw : fh;
            CVPixelBufferRef out = VCamRotBufGet(&gRotBuf, rw, rh, ffmt);
            if (out && VTPixelRotationSessionRotateImage(rs, fresh, out) == noErr) rotated = out;
        }
    }
    return rotated;
}

// Choose 0° vs a quarter-turn so the OBS source lines up with the destination camera
// buffer, by comparing aspect ratios (log space so "2x too wide" and "2x too tall"
// weigh equally). Only 0/90 are considered — a capture buffer is only ever the source
// turned a quarter. Returns 0 or 90 (the caller maps 90 to VCAM_AUTO_ORIENT_DIR).
#if VCAM_AUTO_ORIENT
static long VCamAutoOrientDegrees(CVPixelBufferRef src, CVImageBufferRef dst) {
    size_t sw = CVPixelBufferGetWidth(src),  sh = CVPixelBufferGetHeight(src);
    size_t dw = CVPixelBufferGetWidth(dst),  dh = CVPixelBufferGetHeight(dst);
    if (!sw || !sh || !dw || !dh) return 0;
    double dstAR = (double)dw / (double)dh;
    double d0  = fabs(log(((double)sw / (double)sh) / dstAR));
    double d90 = fabs(log(((double)sh / (double)sw) / dstAR));
    return (d90 < d0) ? 90 : 0;
}
#endif

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

    // Orientation: front-camera mirror + auto-rotate so the OBS frame lines up with
    // THIS client's camera buffer. mirror comes from the sourcePosition hook (config
    // files are unreadable in mediaserverd). Auto-orient turns the portrait OBS frame
    // a quarter (CCW90, VCAM_AUTO_ORIENT_DIR) for a landscape stock-Camera buffer and
    // leaves a portrait TikTok preview at 0°. Matches the closed vcamera's CCW90
    // rotation session; runs once per buffer thanks to the emit dedup.
    BOOL shouldMirror = cfg.mirror || (VCAM_FRONT_AUTOMIRROR && (gSourcePosition == 2));
    long rot = ((cfg.rotation % 360) + 360) % 360;
#if VCAM_AUTO_ORIENT
    if (VCamAutoOrientDegrees(fresh, cameraBuf) == 90) rot = (rot + VCAM_AUTO_ORIENT_DIR) % 360;
#endif

    // One-time geometry diagnostic: log the first few distinct destination sizes
    // seen (each client hands us a different buffer) with the chosen orientation, so a
    // wrong-way rotation can be diagnosed from src/dst dims without guessing.
    {
        static long loggedDst[6]; static int nLogged = 0;
        long key = (long)CVPixelBufferGetWidth(cameraBuf) * 100000 + (long)CVPixelBufferGetHeight(cameraBuf);
        BOOL seen = NO;
        for (int i = 0; i < nLogged; i++) if (loggedDst[i] == key) { seen = YES; break; }
        if (!seen && nLogged < 6) {
            loggedDst[nLogged++] = key;
            VCamLog(@"geom: src=%zux%zu dst=%zux%zu front=%d rot=%ld mirror=%d",
                    CVPixelBufferGetWidth(fresh), CVPixelBufferGetHeight(fresh),
                    CVPixelBufferGetWidth(cameraBuf), CVPixelBufferGetHeight(cameraBuf),
                    (gSourcePosition == 2), rot, shouldMirror);
        }
    }

    // Rotate + transfer as ONE atomic critical section under gVTLock — the closed
    // vcamera holds a single lock across the whole rotate->transfer. Rotate into the
    // REUSED buffer (never a per-frame new one), then transfer into the camera
    // surface. This is safe from the old IOFence wedge now that the emit dedup limits
    // us to one pass per buffer. ScalingMode=Trim (set on the session) aspect-fills.
    [gVTLock lock];
    CVPixelBufferRef rotated = VCamCopyRotatedLocked(fresh, shouldMirror, rot);
    CVPixelBufferRef src = rotated ? rotated : fresh;
    size_t srcW = CVPixelBufferGetWidth(src), srcH = CVPixelBufferGetHeight(src);
    OSStatus ts = VTPixelTransferSessionTransferImage(gTransferSession, src, cameraBuf);
#if VCAM_DEST_COLOR
    // Stamp the destination buffer's COLOUR so downstream consumers interpret our
    // transferred OBS pixels correctly — the closed vcamera does exactly this
    // (RE 0x90110-0x90174): CVBufferSetAttachment(ShouldPropagate) with 709
    // primaries/transfer + 601 matrix. The live preview looked fine without it, but
    // the still-image JPEG encoder reads these tags and, when they are missing/
    // mismatched, the SAVED PHOTO shifts red. ShouldPropagate carries the tags onto
    // the still buffer derived from this shared surface, fixing the photo colour
    // without hooking the photo nodes. Set on success only, inside the lock.
    if (ts == noErr) {
        // Stamp with the SAME matrix the transfer session wrote (VCamDestMatrix),
        // so the still-image encoder converts YCbCr->RGB with the matrix our pixels
        // actually use — otherwise the saved photo shifts red. ShouldPropagate carries
        // the tags onto the still buffer derived from this shared surface.
        VCamStampColour(cameraBuf);
    }
#endif
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
            VTSessionSetProperty(gPhotoTransferSession,
                                 (__bridge CFStringRef)@"EnableGPUAcceleratedTransfer",
                                 VCAM_GPU_ACCEL ? kCFBooleanTrue : kCFBooleanFalse);
#if VCAM_DEST_COLOR
            // Pin the DESTINATION colour like the video session so the still is written
            // AND tagged with the same matrix — the photo-red fix on the encoder path.
            VTSessionSetProperty(gPhotoTransferSession,
                                 kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                                 kCVImageBufferColorPrimaries_ITU_R_709_2);
            VTSessionSetProperty(gPhotoTransferSession,
                                 kVTPixelTransferPropertyKey_DestinationTransferFunction,
                                 kCVImageBufferTransferFunction_ITU_R_709_2);
            VTSessionSetProperty(gPhotoTransferSession,
                                 kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                                 VCamDestMatrix());
#endif
        }
    });
}

static BOOL VCamOverwritePhotoInPlace(CMSampleBufferRef sb) {
    if (!sb) return NO;
    VCamConfig *cfg = [VCamConfig shared];
    if (!cfg.enabled) return NO;

    CVImageBufferRef dst = CMSampleBufferGetImageBuffer(sb);
#if VCAM_DEST_COLOR
    // Correct the still buffer's COLOUR tags FIRST, before the dedup early-return and
    // before the transfer (it is cheap CPU metadata, no GPU work). The still JPEG
    // encoder reads THIS buffer's matrix to convert YCbCr->RGB, so a wrong/absent tag
    // is the "saved photo goes red" symptom. Doing it unconditionally means even a
    // buffer we then skip transferring (already stamped) still carries the right tags.
    if (dst) VCamStampColour(dst);
#endif

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
    BOOL did = NO;
    if (ib) {
#if VCAM_VIDEO_DEDUP
        // Overwrite each sample buffer ONCE (RE of the original @0x84388-0x84450).
        // The graph re-emits the SAME buffer ~10x/frame; transferring every time
        // overloads the shared-surface GPU fence and wedges the preview. Key on our
        // OWN private attachment (VCamDedupKey) rather than the system's
        // kCMSampleBufferAttachmentKey_TransitionID: a re-emit of a buffer WE stamped
        // still carries our key (ShouldPropagate) -> skipped (freeze fix intact), but
        // the system's photo<->video mode-switch transition buffers do NOT carry our
        // key -> we overwrite them too. Keying on the shared TransitionID (0.5.4/0.5.5)
        // made us pass those transition buffers through as the real blurry lens,
        // alternating with OBS -> the sharp/blur cycling on the mode switch.
        CFStringRef dedupKey = VCamDedupKey();
        if (CMGetAttachment(sb, dedupKey, NULL) != NULL) {
            gRDup++;
            did = YES;                          // already OBS -> pass through
        } else {
            did = VCamOverwriteInPlace(ib);
            if (did) {
                CMSetAttachment(sb, dedupKey,
                                (__bridge CFTypeRef)@(1), kCMAttachmentMode_ShouldPropagate);
            }
        }
#else
        did = VCamOverwriteInPlace(ib);
#endif
    }
    ((void (*)(id, SEL, CMSampleBufferRef))orig)(self, _cmd, sb);   // original sb, now overwritten
    gEmitReturns++;                            // heartbeat: orig returned (emit not blocked)

    // Always-on health line: distinguishes "OBS not showing" (replaced=0) from
    // "decoder idle / fail-open" via syslog; the why[] counters pinpoint the cause.
    static uint64_t calls = 0, repl = 0;
    calls++;
    if (did) { repl++; if (repl == 1) VCamLog(@"health: first frame replaced (OBS is live)"); }
    if ((calls % 600) == 0)
        VCamLog(@"health: emits=%llu replaced=%llu dup=%llu why[noFresh=%llu noXfer=%llu xferFail=%llu] "
                "photo[replaced=%llu noFresh=%llu dup=%llu xferFail=%llu]",
                calls, repl, gRDup, gRNoFresh, gRNoXfer, gRXferFail,
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
                "VIDEO_DEDUP=%d PRIVATE_DEDUP=%d DEST_COLOR=%d DEST_MATRIX_709=%d GPU_ACCEL=%d FENCE_FLUSH=%d",
                (unsigned long)gEmitOrigs.count, (unsigned long)gRenderOrigs.count,
                VCAM_HOOK_PHOTO_NODES, VCAM_VIDEO_DEDUP, VCAM_PRIVATE_DEDUP_KEY,
                VCAM_DEST_COLOR, VCAM_DEST_MATRIX_709, VCAM_GPU_ACCEL, VCAM_GPU_FENCE_FLUSH);
    }
}

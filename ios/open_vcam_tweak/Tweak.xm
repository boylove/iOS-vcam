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
// Replicates the closed com.x.vcamera approach per the deep binary reverse
// (../../VCAMERA_OPENVCAM_COMPLETE_REFERENCE.md §2): hook the terminal BufferWorks
// node `BWNodeOutput -emitSampleBuffer:` inside mediaserverd and OVERWRITE THE
// CAMERA'S OWN CVImageBuffer IN PLACE with the decoded RTMP frame via
// VTPixelTransferSessionTransferImage, then pass the SAME (now-overwritten) sample
// buffer to the original. In-place overwrite of the shared IOSurface is what actually
// reaches every client's live preview — apps read that upstream surface directly, so
// emitting a fresh downstream buffer never reaches them (that was the earlier bug).
// Using VideoToolbox (not CIContext), on the terminal emit only (never the
// BWPixelTransferNode), is why the original neither lags nor crashes stock-Camera
// recording. Because mediaserverd sits below every app, this replaces the camera for
// all clients, including RootHide-patched apps (TikTok) that bypass app-level tweak
// injection.
//
// ONE GPU PASS PER FRAME, NO PIXEL ROTATION. The closed vcamera transfers the raw
// decoded frame straight into the camera buffer with a single
// VTPixelTransferSessionTransferImage and does NOT run a per-frame
// VTPixelRotationSession (dynamic RE, memory openvcam-photomode-original-flow: photo
// mode logs exactly one transfer/frame). Orientation is carried by the pipeline's
// existing BWVideoOrientationMetadataNode metadata (hooked pass-through only), which
// the system applies at display/encode — no pixel rotation is needed. An earlier build
// added a SECOND GPU pass (rotate into a shared intermediate, then transfer); that
// extra pass on a shared surface is what closed the GPU IOSurface fence cycle (bug_type
// 284 iofence) and froze mediaserverd on the stock-Camera video<->photo switch.
// Removing it — one direct transfer, like the original — is the fix.
//
// Still-photo capture needs NO dedicated hook: emitSampleBuffer: overwrites the
// upstream shared IOSurface, and the still-image pipeline downstream reads that same
// already-OBS surface (the original's own photo-node hooks are all pass-throughs — see
// VCAMERA_OPENVCAM_COMPLETE_REFERENCE.md §2, memory vcamera-photo-hooks-all-passthrough).
//
// Fail-open everywhere; a missing/stale decoded frame -> pure pass-through (never a
// black or frozen frame).
// ---------------------------------------------------------------------------

#define VCAM_LOG_NAME @"OpenVCam.log"
static const NSTimeInterval kVCamFrameMaxAge = 0.5;   // watchdog: 500ms

// VCAM_DEST_COLOR (default 1 = ON, matching the closed vcamera). Sets the transfer
// session's DESTINATION colour (ITU-R 709 primaries/transfer, per-path YCbCr matrix),
// exactly what the original sets on all three of its transfer sessions (RE
// 0x82494-0x82504). Without it VT infers the destination colour, which comes out WRONG
// for the still-capture buffer. Set 0 only to A/B the inferred-colour behaviour.
#ifndef VCAM_DEST_COLOR
#define VCAM_DEST_COLOR 1
#endif

// Orientation. Faithful to the closed vcamera's camera-overwrite path: the pre-rotation is
// `create90ImageBuffer:` (RE 0x829e0) = kVTRotation_CCW90, NO flip, for BOTH cameras — done
// on INGEST (VCamFrameStore -ingestFrame:), not here. The front-camera selfie mirror is the
// downstream capture pipeline's job (as for the real front camera), so the tweak adds no
// flip. (The "back CW90 / front CCW90+FlipVertical by position" at 0x83e20 is the `run`
// loop's DIFFERENT path (ivars 0xc8/0xd0), which the camera overwrite never reads.)
//   VCAM_AUTO_ORIENT: at emit, pick raw (0°) vs the CCW90 pre-rotated by comparing OBS vs
//     camera aspect — the original's modifyImageBuffer: raw-vs-prerotated select (RE 0x8477c):
//     a portrait TikTok preview matches portrait OBS -> raw; a landscape stock-Camera buffer
//     differs -> the pre-rotated buffer. Set 0 to disable auto-rotate (diagnostic).
#ifndef VCAM_AUTO_ORIENT
#define VCAM_AUTO_ORIENT 1
#endif

// VCAM_GPU_ACCEL (default 0 = CPU transfer). Device-confirmed the practical choice on this
// device: CPU transfer (0.6.3) gives a smooth Photo preview (no ~3s cycle) AND a correct
// front-camera mirror, whereas GPU transfer (0.6.5/0.6.6) both re-froze the preview and
// flipped the mirror 180° (the GPU path appears to write with an inverted vertical origin).
// The closed vcamera ships GPU-accel=true, but it also uses a different orientation-driven
// rotation scheme (ivar 0x100), so matching its GPU path faithfully is a separate task —
// until then CPU transfer is the working config. Set 1 only to A/B the GPU path.
#ifndef VCAM_GPU_ACCEL
#define VCAM_GPU_ACCEL 0
#endif

// VCAM_LANDSCAPE_GATE (default 1 = ON, faithful to the closed vcamera). Overwrite only
// LANDSCAPE (width>=height) destination buffers; the PORTRAIT screen-preview buffer
// (1170x2532) is skipped and INHERITS OBS by propagation from the shared landscape
// capture surface. Device-confirmed that overwriting the portrait DISPLAY buffer directly
// (gate OFF) fences/wedges the GPU (OBS flashes -> freeze -> real camera), so the gate
// stays ON; the freeze between ZSL restarts is fixed instead by making the landscape
// overwrite land synchronously (VCAM_GPU_ACCEL=0, CPU transfer) so propagation is fresh.
// RE: original emit hook 0x7516c-74 (getLive && w>=h) -> modifyImageBuffer.
#ifndef VCAM_LANDSCAPE_GATE
#define VCAM_LANDSCAPE_GATE 1
#endif

// VCAM_DEST_MATRIX_709 (default 0 = 601, matching the closed vcamera). Selects the VIDEO
// transfer session's DESTINATION YCbCr matrix. The full-res still always uses a separate
// 709 session (see VCamConfigXferSession); this flag only A/B-tests the video/preview
// path. See memory openvcam-photo-red-dest-stamp-p3 for the saved-photo colour history.
#ifndef VCAM_DEST_MATRIX_709
#define VCAM_DEST_MATRIX_709 0
#endif

// --- Colour helper, shared by the video and photo transfer paths ---------------
// The destination YCbCr matrix used by the VIDEO transfer session.
static CFStringRef VCamDestMatrix(void) {
#if VCAM_DEST_MATRIX_709
    return kCVImageBufferYCbCrMatrix_ITU_R_709_2;
#else
    return kCVImageBufferYCbCrMatrix_ITU_R_601_4;
#endif
}

// AVCaptureDevicePosition: 0 unspecified, 1 back, 2 front. Updated from the
// FigCaptureSourceConfiguration -sourcePosition hook; drives front-camera auto-mirror
// (the original hooks this too, report §3.8).
static volatile long gSourcePosition = 0;

// ---------------------------------------------------------------------------
// Stall watchdog / heartbeat (diagnostic for the "moves once then freezes" bug).
//
// The health line is printed FROM INSIDE the emit hook — so if the capture thread ever
// blocks inside our replacement, that log line never fires again and the freeze looks
// identical to "idle". This heartbeat runs on its OWN thread and reports the emit
// counter from the outside, so a hang shows up as "emits STALLED at N". Pure observer,
// no locks touched — safe to leave on in release builds.
static volatile uint64_t gEmitEntries  = 0;   // VCamEmit entered
static volatile uint64_t gEmitReturns  = 0;   // VCamEmit's orig() returned

static void VCamStartHeartbeat(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            uint64_t last = 0;
            BOOL stalledLogged = NO;
            for (;;) {
                sleep(2);
                uint64_t now          = gEmitEntries;
                uint64_t emitInflight = gEmitEntries - gEmitReturns;
                if (now != last) {                 // frames still flowing -> healthy
                    last = now;
                    stalledLogged = NO;
                } else if (now > 0 && !stalledLogged) {
                    // Counter was advancing and has now been frozen for ~2s: the capture
                    // thread is blocked, not merely idle (idle still emits real-camera
                    // frames, so the counter keeps rising).
                    stalledLogged = YES;
                    VCamLog(@"HEARTBEAT: emits STALLED at %llu (emitInflight=%llu) "
                            "-> mediaserverd capture thread BLOCKED IN LIVE OVERWRITE",
                            now, emitInflight);
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
// The closed vcamera converts the decoded RTMP frame into a camera-format buffer with
// VTPixelTransferSession (scale + pixel-format / colour-range conversion), NOT
// CoreImage. CIContext rendering a decoded frame into a biplanar YCbCr (420v/420f)
// buffer with a NULL colour space came out BLACK downstream; VTPixelTransferSession does
// the YCbCr<->YCbCr and video<->full-range conversion correctly. The session adapts to
// the src/dst buffers on each call, so we create it once and reuse it, serialised by
// VCamFrameStore's single engine lock (held across the emit pick + transfer) because the
// capture graph can service several source nodes concurrently. This is the ONLY GPU pass in
// the emit hot path — the CCW90 pre-rotation happens once per frame on the decode thread.
// ---------------------------------------------------------------------------
// ONE transfer session for ALL buffers (preview, video, AND the full-res still), 601
// matrix — exactly like the closed vcamera, which creates three IDENTICAL 601 sessions
// but its modifyImageBuffer uses only one (ivar 0x88) for every overwrite (decisive
// disas, memory openvcam-emit-throttle-not-dedup). No per-path 709 still split.
static VTPixelTransferSessionRef gTransferSession;
// The single engine lock (== closed vcamera ivar 0x18) now lives in VCamFrameStore and is
// held across BOTH the ingest rotation AND the emit transfer below — there is no separate
// transfer lock here (two locks are exactly what caused the 0.5.7 GPU-fence deadlock).

// Configure the transfer session exactly like the closed vcamera: Trim scaling +
// GPU-accel + pinned 709 primaries/transfer + 601 destination YCbCr matrix. One config
// for every buffer (preview, video, still) — the original does not split video/still.
static void VCamConfigXferSession(VTPixelTransferSessionRef s, CFStringRef destMatrix) {
    if (!s) return;
    // Without a scaling mode the transfer FAILS whenever src/dst sizes differ (the normal
    // case) -> NULL replacement -> real camera. Trim matches the closed vcamera.
    VTSessionSetProperty(s, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Trim);
    // GPU-accelerated transfer (string key; no public constant), matching the original.
    VTSessionSetProperty(s, (__bridge CFStringRef)@"EnableGPUAcceleratedTransfer",
                         VCAM_GPU_ACCEL ? kCFBooleanTrue : kCFBooleanFalse);
#if VCAM_DEST_COLOR
    // Pin the destination colour like the closed vcamera (709 primaries/transfer); the
    // matrix is per-path (601 video / 709 still — see above).
    VTSessionSetProperty(s, kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                         kCVImageBufferColorPrimaries_ITU_R_709_2);
    VTSessionSetProperty(s, kVTPixelTransferPropertyKey_DestinationTransferFunction,
                         kCVImageBufferTransferFunction_ITU_R_709_2);
    VTSessionSetProperty(s, kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, destMatrix);
#endif
}

static void VCamEnsureSessions(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &gTransferSession);
        VCamConfigXferSession(gTransferSession, VCamDestMatrix());   // 601 for everything
    });
}

// Always-on failure-reason counters so the periodic health line reports WHY an overwrite
// was skipped (fail-open): no fresh decoded frame, no transfer session, or the VT
// transfer failed. Read in the health line; that is the reliable diagnostic
// (startup-gated debug logs fire before a syslog capture can attach).
static uint64_t gRNoFresh, gRNoXfer, gRXferFail;

// ---------------------------------------------------------------------------
// Rotation moved to INGEST — faithful to the closed vcamera. The decoded OBS frame is
// pre-rotated CCW90 on the decode thread inside VCamFrameStore (-ingestFrame: ->
// create90ImageBuffer: equivalent, ivar 0x70); the emit hot path below does NO rotation —
// it only picks raw-vs-prerotated + one transfer (== modifyImageBuffer: 0x84458). Both run
// under VCamFrameStore's single engine lock, so rotate and transfer never overlap on the
// GPU (splitting that into two locks is what caused the 0.5.7 IOSurface-fence deadlock).
// ---------------------------------------------------------------------------

// Choose 0° vs a quarter-turn so the OBS source lines up with the destination camera
// buffer, by comparing aspect ratios (log space so "2x too wide" and "2x too tall" weigh
// equally). Only 0/90 are considered — a capture buffer is only ever the source turned a
// quarter. Returns 0 or 90 (the caller maps 90 to a position-driven CW90/CCW90).
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
// exactly like the closed vcamera's -[<core> modifyImageBuffer:]: it calls
// VTPixelTransferSessionTransferImage(session, OBS frame, CAMERA image buffer), writing
// straight into the camera's shared IOSurface. THAT is what actually reaches the app's
// live preview — apps read that shared surface directly, so substituting a new sample
// buffer downstream does not reach them. Returns YES on overwrite; on any failure returns
// NO and the caller passes the real frame.
static uint64_t gRPortrait;   // landscape-gate skips (health diagnostic)

static BOOL VCamOverwriteInPlace(CVImageBufferRef cameraBuf) {
    if (!cameraBuf) return NO;
    VCamConfig *cfg = [VCamConfig shared];
    if (!cfg.enabled) return NO;

#if VCAM_LANDSCAPE_GATE
    // Overwrite only LANDSCAPE buffers, like the closed vcamera (see VCAM_LANDSCAPE_GATE).
    // Portrait buffers inherit OBS from the shared landscape capture surface, so skipping
    // them is invisible AND keeps the overwrite rate at the original's level. Not a
    // failure: a portrait dst legitimately needs no direct overwrite.
    if (CVPixelBufferGetWidth(cameraBuf) < CVPixelBufferGetHeight(cameraBuf)) {
        gRPortrait++;
        return NO;
    }
#endif

    VCamEnsureSessions();
    if (!gTransferSession) { gRNoXfer++; return NO; }

    VCamFrameStore *store = [VCamFrameStore shared];
    // Single engine-lock critical section across pick + transfer — the SAME lock the ingest
    // holds while pre-rotating (faithful to the original's one ivar-0x18 lock across
    // setYUVSampleBuffer: and modifyImageBuffer:). NO rotation and NO flip here: the ingest
    // already produced the CCW90 buffer, and the front-camera selfie mirror is the downstream
    // capture pipeline's job (as it is for the real front camera).
    if (![store beginEmitAccessWithMaxAge:kVCamFrameMaxAge]) { gRNoFresh++; return NO; }
    CVPixelBufferRef raw = [store rawFrameLocked];
    CVPixelBufferRef rot = [store rotatedFrameLocked];
    // Pick raw (same orientation as dst) vs the CCW90 pre-rotated (differing) — exactly the
    // original's modifyImageBuffer: raw-vs-prerotated select (RE 0x8477c-0x847b4).
    CVPixelBufferRef src = raw;
#if VCAM_AUTO_ORIENT
    BOOL usedRotated = (rot && VCamAutoOrientDegrees(raw, cameraBuf) == 90);
    if (usedRotated) src = rot;
#else
    BOOL usedRotated = NO;
#endif
    size_t srcW = CVPixelBufferGetWidth(src), srcH = CVPixelBufferGetHeight(src);
    // ONE transfer, one 601 session for every buffer (preview, video, still) — no per-size
    // routing, like the closed vcamera. ScalingMode=Trim (on the session) aspect-fills.
    OSStatus ts = VTPixelTransferSessionTransferImage(gTransferSession, src, cameraBuf);
    [store endEmitAccess];

    // One-time geometry diagnostic (first few distinct dst sizes), logged AFTER unlock so
    // the lock is held only around the transfer.
    {
        static long loggedDst[6]; static int nLogged = 0;
        long key = (long)CVPixelBufferGetWidth(cameraBuf) * 100000 + (long)CVPixelBufferGetHeight(cameraBuf);
        BOOL seen = NO;
        for (int i = 0; i < nLogged; i++) if (loggedDst[i] == key) { seen = YES; break; }
        if (!seen && nLogged < 6) {
            loggedDst[nLogged++] = key;
            VCamLog(@"geom: src=%zux%zu dst=%zux%zu rotated=%d",
                    srcW, srcH,
                    CVPixelBufferGetWidth(cameraBuf), CVPixelBufferGetHeight(cameraBuf),
                    usedRotated);
        }
    }

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
// Hook plumbing for private mediaserverd classes (objc_getClass + MSHookMessageEx)
// ---------------------------------------------------------------------------
static NSMutableDictionary<NSValue *, NSValue *> *gEmitOrigs;    // Class -> IMP

static IMP VCamFindOrig(NSMutableDictionary<NSValue *, NSValue *> *map, id obj) {
    Class c = object_getClass(obj);
    while (c) {
        NSValue *v = map[[NSValue valueWithPointer:(__bridge void *)c]];
        if (v) return (IMP)[v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

// -[BWNodeOutput emitSampleBuffer:] — overwrite the camera's image buffer IN PLACE
// (exactly like vcamera's -[<core> modifyImageBuffer:]), then call the original with the
// ORIGINAL sample buffer. This is the ONLY node the original modifies; the render nodes
// are left untouched (see the deep reverse report).
static void VCamEmit(id self, SEL _cmd, CMSampleBufferRef sb) {
    IMP orig = VCamFindOrig(gEmitOrigs, self);
    if (!orig) return;
    gEmitEntries++;                            // heartbeat: entered (before any work)
    [[VCamRTMPSource shared] ensureStarted];   // idempotent; keeps the RTMP puller alive
    CVImageBufferRef ib = sb ? CMSampleBufferGetImageBuffer(sb) : NULL;
    BOOL did = NO;
    if (ib) {
        // Overwrite every landscape buffer, no dedup — instruction-level RE of the
        // original's video -[<core> modifyImageBuffer:] @0x84458 shows it does exactly
        // ONE VTPixelTransferSessionTransferImage per call, an unconditional in-place
        // overwrite every emit (the landscape gate, not a dedup, is what keeps the
        // overwrite rate safe — see VCAM_LANDSCAPE_GATE).
        did = VCamOverwriteInPlace(ib);
    }
    ((void (*)(id, SEL, CMSampleBufferRef))orig)(self, _cmd, sb);   // original sb, now overwritten
    gEmitReturns++;                            // heartbeat: orig returned (emit not blocked)

    // Always-on health line: distinguishes "OBS not showing" (replaced=0) from
    // "decoder idle / fail-open" via syslog; the why[] counters pinpoint the cause.
    static uint64_t calls = 0, repl = 0;
    calls++;
    if (did) { repl++; if (repl == 1) VCamLog(@"health: first frame replaced (OBS is live)"); }
    if ((calls % 600) == 0)
        VCamLog(@"health: emits=%llu replaced=%llu why[noFresh=%llu noXfer=%llu xferFail=%llu portrait=%llu]",
                calls, repl, gRNoFresh, gRNoXfer, gRXferFail, gRPortrait);
}

// -[FigCaptureSourceConfiguration sourcePosition] — records which physical camera is
// active (front/back) so the overwrite path can auto-mirror the front camera. Pure
// observer: always returns the original value, never fails the call.
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

        // Hook ONLY the terminal BWNodeOutput emitSampleBuffer:. Per the binary analysis
        // of the closed vcamera (VCAMERA_OPENVCAM_COMPLETE_REFERENCE.md §2), that is the
        // single place it modifies the frame: it overwrites the camera's own image buffer
        // IN PLACE there (via VTPixelTransfer), and passes the same sample buffer on.
        // Modifying the shared IOSurface is what reaches the app's live preview. vcamera
        // hooks the render nodes too but only as pass-through, so we don't hook them at
        // all — which also avoids the BWPixelTransferNode recording-crash path entirely.
        // The still-image pipeline reads the same already-overwritten shared surface, so
        // the shutter captures OBS with no dedicated photo hook.
        VCamHook("BWNodeOutput", @selector(emitSampleBuffer:), (IMP)VCamEmit, gEmitOrigs);

        // Front/back detection for auto-mirror (config files unreadable here).
        VCamHookSourcePosition();

        // Start the stall watchdog BEFORE frames flow: it reports from its own thread if
        // the capture thread ever wedges inside our hook, so the "moves once then freezes"
        // symptom shows up as "emits STALLED" instead of silence.
        VCamStartHeartbeat();

        // Start pulling immediately; frames only get used once enabled + fresh.
        [[VCamRTMPSource shared] ensureStarted];
        // Log the compile config so the syslog itself proves WHICH build is running.
        VCamLog(@"hooks installed (%lu emit) DEST_COLOR=%d DEST_MATRIX_709=%d GPU_ACCEL=%d LANDSCAPE_GATE=%d",
                (unsigned long)gEmitOrigs.count,
                VCAM_DEST_COLOR, VCAM_DEST_MATRIX_709, VCAM_GPU_ACCEL, VCAM_LANDSCAPE_GATE);
    }
}

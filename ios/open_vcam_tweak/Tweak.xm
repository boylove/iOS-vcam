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

// Orientation. FLIP AXIS is faithful to the closed vcamera (RE 0x83e68): the front-camera
// selfie mirror is kVTPixelRotationPropertyKey_FlipVerticalOrientation (the original imports
// ONLY FlipVertical), never FlipHorizontal. The original drives its rotation DIRECTION from
// camera position (ivar 0x100, RE 0x83e20: back CW90 / front CCW90) — but those keys are
// relative to ITS OWN decoded frame; OpenVCam's decoder delivers a different origin, so
// device-empirically BOTH cameras need CCW90 here (literal CW90 inverted the back camera
// 180°). It rotates ONCE per buffer into a reused buffer under gVTLock (single-lock).
//   VCAM_AUTO_ORIENT: pick raw (0°) vs a quarter-turn by comparing OBS vs camera aspect —
//     this is the original's emit-side raw-vs-prerotated selection (RE 0x8477c): a portrait
//     TikTok preview matches portrait OBS -> raw; a landscape stock-Camera buffer differs
//     -> the rotated buffer. Set 0 to disable auto-rotate (diagnostic; relies on cfg.rotation).
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
// gVTLock because the capture graph can service several source nodes concurrently. This
// is the ONLY GPU pass per frame — no VTPixelRotationSession; orientation is left to the
// pipeline's existing metadata (see the header note).
// ---------------------------------------------------------------------------
// ONE transfer session for ALL buffers (preview, video, AND the full-res still), 601
// matrix — exactly like the closed vcamera, which creates three IDENTICAL 601 sessions
// but its modifyImageBuffer uses only one (ivar 0x88) for every overwrite (decisive
// disas, memory openvcam-emit-throttle-not-dedup). No per-path 709 still split.
static VTPixelTransferSessionRef gTransferSession;
// NSRecursiveLock, matching the closed vcamera's engine _lock (@0x823f8) — the rotate +
// transfer critical section can re-enter, and a plain NSLock would self-deadlock.
static NSRecursiveLock *gVTLock;

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
        gVTLock = [[NSRecursiveLock alloc] init];
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
// Rotation / front-camera mirror (VTPixelRotationSession), matching the closed
// vcamera's _pixelRotationSession. The decoded OBS frame is rotated into ONE reused
// buffer (never a fresh buffer per frame) inside gVTLock, then the transfer session
// scales/converts it into the camera surface. Reusing the buffer + single lock is the
// original's discipline; this runs once per buffer.
// ---------------------------------------------------------------------------
typedef struct { CVPixelBufferRef buf; size_t w, h; OSType fmt; } VCamRotBuf;
static VCamRotBuf gRotBuf;
static CFTypeRef gRotationSession;   // VTPixelRotationSessionRef, or NULL

// Cached rotation-output buffer; (re)allocated only when geometry changes. The SAME
// buffer is returned every call (cache-owned; caller must NOT release). Caller MUST hold
// gVTLock.
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
// Returns NULL when no rotation/mirror is needed (caller transfers `fresh` directly) or
// on failure. Caller MUST already hold gVTLock so rotate+transfer is one uninterrupted
// critical section (the original holds a single lock across both).
static CVPixelBufferRef VCamCopyRotatedLocked(CVPixelBufferRef fresh, BOOL flipVertical, long rot) {
    if (!flipVertical && rot == 0) return NULL;
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
            // FlipVerticalOrientation — the original's ONLY imported flip key (RE 0x83e68).
            // The closed vcamera mirrors the FRONT camera with FlipVertical coupled to the
            // CCW90 rotation, NEVER FlipHorizontal (which is exactly 180° off). See memory
            // openvcam-original-rotation-flipvertical.
            VTSessionSetProperty(rs, kVTPixelRotationPropertyKey_FlipVerticalOrientation,
                                 flipVertical ? kCFBooleanTrue : kCFBooleanFalse);
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

    CVPixelBufferRef fresh = [[VCamFrameStore shared] copyFreshFrameWithMaxAge:kVCamFrameMaxAge];
    if (!fresh) { gRNoFresh++; return NO; }             // stale/no stream -> real camera

    VCamEnsureSessions();
    if (!gTransferSession) { gRNoXfer++; CVPixelBufferRelease(fresh); return NO; }

    // Orientation. The FLIP AXIS is faithful to the closed vcamera (RE 0x83e68): the front
    // camera selfie-mirror is kVTPixelRotationPropertyKey_FlipVerticalOrientation, NEVER
    // FlipHorizontal (that was the real 180°-off bug). The ROTATION DIRECTION, however, is
    // PIPELINE-RELATIVE, not literally copyable: the original's per-position keys (back CW90
    // / front CCW90, RE 0x83e20-0x83e4c) are defined against ITS OWN decoded frame, but
    // OpenVCam's H264 decoder hands us the OBS frame at a different origin — so replicating
    // the original's literal CW90 for the back camera came out 180° (upside down) on-device
    // (user 2026-07-10). Device-correct here: CCW90 for BOTH cameras; only the FRONT adds the
    // FlipVertical mirror. The aspect compare (VCamAutoOrientDegrees) only decides WHETHER a
    // quarter-turn is needed — the original's emit-side raw-vs-prerotated selection (RE
    // 0x8477c-0x847b4). gSourcePosition comes from the -sourcePosition hook.
    BOOL front = (gSourcePosition == 2);
    long rot = 0;
    BOOL flipVertical = NO;
#if VCAM_AUTO_ORIENT
    BOOL needTurn = (VCamAutoOrientDegrees(fresh, cameraBuf) == 90);
#else
    BOOL needTurn = NO;
#endif
    if (needTurn) {
        rot = 270;                // CCW90 for both cameras (device-correct on OpenVCam's decode)
        flipVertical = front;     // front camera adds FlipVertical (the selfie mirror, RE 0x83e68)
    }
    // Manual config overrides (only matter if a build ever makes cfg readable in
    // mediaserverd): a non-zero cfg.rotation adds on top; cfg.mirror forces the flip.
    rot = (((rot + cfg.rotation) % 360) + 360) % 360;
    if (cfg.mirror) flipVertical = YES;

    // One-time geometry diagnostic: log the first few distinct destination sizes seen
    // (each client hands us a different buffer) with the chosen orientation, so a
    // wrong-way rotation can be diagnosed from src/dst dims without guessing.
    {
        static long loggedDst[6]; static int nLogged = 0;
        long key = (long)CVPixelBufferGetWidth(cameraBuf) * 100000 + (long)CVPixelBufferGetHeight(cameraBuf);
        BOOL seen = NO;
        for (int i = 0; i < nLogged; i++) if (loggedDst[i] == key) { seen = YES; break; }
        if (!seen && nLogged < 6) {
            loggedDst[nLogged++] = key;
            VCamLog(@"geom: src=%zux%zu dst=%zux%zu front=%d rot=%ld flipV=%d",
                    CVPixelBufferGetWidth(fresh), CVPixelBufferGetHeight(fresh),
                    CVPixelBufferGetWidth(cameraBuf), CVPixelBufferGetHeight(cameraBuf),
                    (gSourcePosition == 2), rot, flipVertical);
        }
    }

    // Rotate + transfer as ONE atomic critical section under gVTLock — the closed vcamera
    // holds a single lock across the whole rotate->transfer. Rotate into the REUSED buffer
    // (never a per-frame new one), then transfer into the camera surface.
    // ScalingMode=Trim (set on the session) aspect-fills.
    [gVTLock lock];
    CVPixelBufferRef rotated = VCamCopyRotatedLocked(fresh, flipVertical, rot);
    CVPixelBufferRef src = rotated ? rotated : fresh;
    size_t srcW = CVPixelBufferGetWidth(src), srcH = CVPixelBufferGetHeight(src);
    // One 601 session for every buffer — preview, video, and the full-res still —
    // exactly like the closed vcamera (no per-size routing).
    OSStatus ts = VTPixelTransferSessionTransferImage(gTransferSession, src, cameraBuf);
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

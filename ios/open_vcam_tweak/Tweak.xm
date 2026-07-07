#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <stdarg.h>
#import <math.h>

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
// Still-photo capture is covered by the same in-place overwrite on the photo
// render nodes (BWStillImageScalerNode / BWPhotoEncoderNode), guarded by a
// TransitionID attachment so the one buffer that flows through several photo
// nodes is only overwritten once (report §2.3).
//
// See memory: vcamera-mediaserverd-hookpoints; report:
// VCAMERA_FRAME_REPLACEMENT_DEEP_REVERSE.md. Fail-open everywhere; a missing/stale
// decoded frame -> pure pass-through (never a black or frozen frame).
// ---------------------------------------------------------------------------

#define VCAM_LOG_NAME @"OpenVCam.log"
static const NSTimeInterval kVCamFrameMaxAge = 0.5;   // watchdog: 500ms

// Front-camera auto-mirror. mediaserverd's sandbox blocks every config file
// (EXECUTION-PLAN §4.4), so mirroring can't be driven by vc.plist. Instead we
// track the active capture source position (hooked below) and mirror the
// injected frame horizontally on the front camera, matching a real selfie.
// Set to 0 (or -DVCAM_FRONT_AUTOMIRROR=0) if the desired orientation is the
// opposite — this is the one knob to flip after a visual check.
#ifndef VCAM_FRONT_AUTOMIRROR
#define VCAM_FRONT_AUTOMIRROR 1
#endif

// Auto-orientation (aspect-ratio driven, matching the closed vcamera).
//
// The original does NOT hardcode rotate-90 / rotate-0. It reads the DESTINATION
// camera buffer's dimensions each frame and picks, between the raw decoded frame
// and a 90°-rotated intermediate, whichever aspect ratio better matches the
// target buffer — then VTPixelTransfer scales that into the camera buffer. This
// is what makes one code path work across every client: TikTok's portrait
// preview, the stock Camera's landscape video buffer (~2112x1188 16:9), a 4:3
// still buffer, front/back at different resolutions, etc.
//
// We do the same in VCamChooseRotation: compare |srcAR - dstAR| for the source
// as-is vs. rotated 90°, and rotate only if rotating brings the aspect ratio
// closer to the destination. So a portrait source into a portrait buffer (TikTok)
// stays unrotated; a portrait source into a landscape buffer (stock-Camera video)
// rotates — killing both the distortion and the pipeline's residual 90° turn.
// VCAM_AUTO_ORIENT_DIR selects which way to rotate when a rotation is chosen; if
// the stock-Camera result comes out rotated the WRONG way, flip it to 270.
#ifndef VCAM_AUTO_ORIENT
#define VCAM_AUTO_ORIENT 1
#endif
// 270, not 90: on the stock Camera (landscape video buffer) a +90 quarter-turn
// came out 180° upside-down in the RECORDED video (device-tested). The opposite
// quarter-turn (270) lines it up. TikTok's portrait preview picks 0° so this knob
// never touches it. Flip back to 90 with -DVCAM_AUTO_ORIENT_DIR=90 if a future
// device turns the other way.
#ifndef VCAM_AUTO_ORIENT_DIR
#define VCAM_AUTO_ORIENT_DIR 270
#endif

// Still-photo replacement. The closed vcamera also overwrites the photo path
// (report §2.3: -[<core> modifyPixelBuffer:] on the BWStillImageScalerNode /
// BWPhotoEncoderNode chain, with a TransitionID dedup mark).
//
// DISABLED BY DEFAULT after device testing: on THIS device (Dopamine iOS 16.1.2)
// hooking the photo scaler/encoder nodes and overwriting their buffer in place
// HANGS mediaserverd on the stock-Camera photo->video switch (the system watchdog
// then restarts mediaserverd and the frame falls back to the real lens). This is
// the highest-risk path called out in EXECUTION-PLAN §4.6. The live-video path
// (BWNodeOutput emitSampleBuffer:) is unaffected and verified working, so we ship
// video-only. Re-enable for experimentation with -DVCAM_HOOK_PHOTO_NODES=1, but it
// needs a different approach (the closed vcamera gates on a detected face and uses
// a dedicated session — replicating that safely is future work).
#ifndef VCAM_HOOK_PHOTO_NODES
#define VCAM_HOOK_PHOTO_NODES 0
#endif

// AVCaptureDevicePosition: 0 unspecified, 1 back, 2 front. Updated from the
// FigCaptureSourceConfiguration -sourcePosition hook; read on the capture path.
static volatile long gSourcePosition = 0;

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
// graph can service several source nodes concurrently. Rotation / front-camera
// mirror is layered on top with VTPixelRotationSession (see VCamCopyRotated).
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
            // Normal = stretch to fill (matches the previous stretch behaviour).
            VTSessionSetProperty(gTransferSession, kVTPixelTransferPropertyKey_ScalingMode,
                                 kVTScalingMode_Normal);
        }
    });
}

// A CVPixelBufferPool keyed on (width, height, pixel format); recreated only when
// those change. Used for the rotation intermediate buffer (VCamCopyRotated).
typedef struct { CVPixelBufferPoolRef pool; size_t w, h; OSType fmt; } VCamPool;

// Always-on failure-reason counters so the periodic health line reports WHY an
// overwrite was skipped (fail-open): no fresh decoded frame, no transfer session,
// or the VT transfer failed. Read in the health line; that is the reliable
// diagnostic (startup-gated debug logs fire before a syslog capture can attach).
static uint64_t gRNoFresh, gRNoXfer, gRXferFail;

static CVPixelBufferRef VCamPoolCopy(VCamPool *p, size_t w, size_t h, OSType fmt) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });

    CVPixelBufferRef out = NULL;
    [lock lock];
    if (!p->pool || p->w != w || p->h != h || p->fmt != fmt) {
        if (p->pool) { CVPixelBufferPoolRelease(p->pool); p->pool = NULL; }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey     : @(fmt),
            (id)kCVPixelBufferWidthKey               : @(w),
            (id)kCVPixelBufferHeightKey              : @(h),
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},   // VT needs IOSurface-backed buffers
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                (__bridge CFDictionaryRef)attrs, &p->pool);
        p->w = w; p->h = h; p->fmt = fmt;
    }
    if (p->pool) CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, p->pool, &out);
    [lock unlock];
    return out;
}

// Rotation / front-camera mirror via VTPixelRotationSession (iOS 16+), matching
// the closed vcamera's _pixelRotationSession. Rotates + optionally horizontally
// flips the decoded frame into an intermediate buffer (source pixel format,
// rotated dimensions); the transfer session then scales/converts it to the
// camera format. Stored as CFTypeRef so the file-scope declaration needs no
// availability annotation; every use is inside `if (@available(iOS 16, *))`.
// On iOS < 16 rotation is skipped (the frame still shows, just unrotated).
static VCamPool gRotPool;
static CFTypeRef gRotationSession;   // VTPixelRotationSessionRef, or NULL

static CVPixelBufferRef VCamCopyRotated(CVPixelBufferRef fresh, BOOL mirror, long rot) {
    if (!mirror && rot == 0) return NULL;          // nothing to do -> transfer 'fresh' directly
    CVPixelBufferRef rotated = NULL;
    if (@available(iOS 16.0, *)) {
        [gVTLock lock];
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
            size_t rw = (rot == 90 || rot == 270) ? fh : fw;   // rotation swaps W/H
            size_t rh = (rot == 90 || rot == 270) ? fw : fh;
            rotated = VCamPoolCopy(&gRotPool, rw, rh, ffmt);
            if (rotated && VTPixelRotationSessionRotateImage(rs, fresh, rotated) != noErr) {
                CVPixelBufferRelease(rotated);
                rotated = NULL;
            }
        }
        [gVTLock unlock];
    }
    return rotated;
}

// Decide how many degrees to rotate the OBS source so its pixels line up with the
// destination CAMERA buffer — mirroring how the closed vcamera chooses between its
// raw decoded frame and its rotated intermediate (report §2.2/§2.4): the choice is
// driven by the SOURCE vs DESTINATION geometry, not a fixed angle. Different
// clients hand us different buffers — TikTok a portrait preview, the stock Camera a
// landscape video buffer or a 4:3 still — so a fixed 90° is wrong for half of them.
//
// We compare the destination's aspect ratio against the source's at 0° vs at 90°
// and pick whichever orientation is closer to the destination. Ties (e.g. a square
// buffer) keep 0°. Only 0/90 are considered here because a capture buffer is only
// ever the source rotated by a quarter turn; explicit cfg.rotation still composes
// on top. Returns 0 or 90 (the caller adds it to any configured rotation).
#if VCAM_AUTO_ORIENT
static long VCamAutoOrientDegrees(CVPixelBufferRef src, CVImageBufferRef dst) {
    size_t sw = CVPixelBufferGetWidth(src),  sh = CVPixelBufferGetHeight(src);
    size_t dw = CVPixelBufferGetWidth(dst),  dh = CVPixelBufferGetHeight(dst);
    if (sw == 0 || sh == 0 || dw == 0 || dh == 0) return 0;

    double dstAR = (double)dw / (double)dh;
    double arAt0  = (double)sw / (double)sh;   // source as-is
    double arAt90 = (double)sh / (double)sw;   // source turned a quarter -> W/H swap

    // Compare in log space so e.g. 2x too wide and 2x too tall weigh equally.
    double d0  = fabs(log(arAt0  / dstAR));
    double d90 = fabs(log(arAt90 / dstAR));
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

    // Rotate / front-camera mirror first (config files are unreadable in
    // mediaserverd, so mirror is driven by the sourcePosition hook).
    BOOL frontCamera = (gSourcePosition == 2);
    BOOL shouldMirror = cfg.mirror || (VCAM_FRONT_AUTOMIRROR && frontCamera);
    long rot = ((cfg.rotation % 360) + 360) % 360;

    // Auto-orientation: align the OBS source to the destination buffer's geometry
    // (see VCamAutoOrientDegrees) rather than assuming a fixed angle. The stock
    // Camera video buffer is landscape (rotate the portrait OBS frame 90°); TikTok's
    // preview buffer is portrait (already aligned -> 0°); a 4:3 still lands closer to
    // one of the two and is picked accordingly. VCAM_AUTO_ORIENT_DIR flips the sense
    // (90 vs 270) if the result turns the wrong way. Explicit cfg.rotation composes
    // on top so a user override still applies.
#if VCAM_AUTO_ORIENT
    long autoDeg = VCamAutoOrientDegrees(fresh, cameraBuf);
    if (autoDeg == 90) {
        rot = (rot + VCAM_AUTO_ORIENT_DIR) % 360;
    }
#else
    long autoDeg = 0;
#endif

    // One-time geometry diagnostic: log the first few distinct destination sizes
    // seen (each client hands us a different buffer) with the chosen orientation,
    // so a wrong-way rotation can be diagnosed from src/dst dims without guessing.
    {
        static long loggedDst[6]; static int nLogged = 0;
        long key = (long)CVPixelBufferGetWidth(cameraBuf) * 100000 + (long)CVPixelBufferGetHeight(cameraBuf);
        BOOL seen = NO;
        for (int i = 0; i < nLogged; i++) if (loggedDst[i] == key) { seen = YES; break; }
        if (!seen && nLogged < 6) {
            loggedDst[nLogged++] = key;
            VCamLog(@"geom: src=%zux%zu dst=%zux%zu front=%d autoDeg=%ld rot=%ld mirror=%d",
                    CVPixelBufferGetWidth(fresh), CVPixelBufferGetHeight(fresh),
                    CVPixelBufferGetWidth(cameraBuf), CVPixelBufferGetHeight(cameraBuf),
                    frontCamera, autoDeg, rot, shouldMirror);
        }
    }

    CVPixelBufferRef rotated = VCamCopyRotated(fresh, shouldMirror, rot);
    CVPixelBufferRef src = rotated ? rotated : fresh;

    // Scale + pixel-format/range convert the OBS frame directly INTO the camera
    // buffer. Serialised by gVTLock (the capture graph is multi-threaded), like
    // the original's per-instance lock around its transfer session. ScalingMode
    // is set on the session (VCamEnsureSessions) so a src/dst size mismatch works.
    [gVTLock lock];
    OSStatus ts = VTPixelTransferSessionTransferImage(gTransferSession, src, cameraBuf);
    [gVTLock unlock];

    size_t srcW = CVPixelBufferGetWidth(src), srcH = CVPixelBufferGetHeight(src);
    if (rotated) CVPixelBufferRelease(rotated);
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
// Photo / still-capture path — mirrors the closed vcamera's
// -[<core> modifyPixelBuffer:] (report §2.3).
//
// A still-capture sample buffer flows through several photo nodes in turn
// (BWStillImageScalerNode -> BWPhotoEncoderNode -> preview/thumbnail), so the
// original overwrites the image buffer IN PLACE and stamps a dedup attachment so
// the same buffer is never overwritten twice as it moves down the graph. We do
// the same: overwrite once at the earliest photo node, tag the buffer, and skip
// any node that sees the tag. A DEDICATED transfer session (matching the
// original's second session at +0x90) keeps still captures off the live-video
// session's lock. Fail-open everywhere: any miss -> the real still frame.
//
// The original repurposes CoreMedia's kCMSampleBufferAttachmentKey_TransitionID
// for the dedup mark; we use a private key instead so we never perturb the real
// transition semantics the photo encoder may rely on. The original also gates
// this on a detected face (its beauty path); we replace unconditionally, which
// is what a virtual camera wants — the OBS frame lands in the photo whether or
// not a face is present.
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
            VTSessionSetProperty(gPhotoTransferSession, kVTPixelTransferPropertyKey_ScalingMode,
                                 kVTScalingMode_Normal);
        }
    });
}

static BOOL VCamOverwritePhotoInPlace(CMSampleBufferRef sb) {
    if (!sb) return NO;
    VCamConfig *cfg = [VCamConfig shared];
    if (!cfg.enabled) return NO;

    // Dedup: this still buffer may pass through several photo nodes; overwrite
    // exactly once. A propagating attachment carries the mark onto any buffer the
    // scaler derives from it, so the encoder/preview/thumbnail nodes skip it.
    if (CMGetAttachment(sb, CFSTR("VCamTransitionID"), NULL) != NULL) {
        gRPhotoDup++;
        return YES;   // already ours from an upstream node
    }

    CVImageBufferRef dst = CMSampleBufferGetImageBuffer(sb);
    if (!dst) return NO;

    CVPixelBufferRef fresh = [[VCamFrameStore shared] copyFreshFrameWithMaxAge:kVCamFrameMaxAge];
    if (!fresh) { gRPhotoNoFresh++; return NO; }        // stale/no stream -> real still

    VCamEnsurePhotoSession();
    if (!gPhotoTransferSession) { CVPixelBufferRelease(fresh); return NO; }

    BOOL frontCamera = (gSourcePosition == 2);
    BOOL shouldMirror = cfg.mirror || (VCAM_FRONT_AUTOMIRROR && frontCamera);
    long rot = ((cfg.rotation % 360) + 360) % 360;
    CVPixelBufferRef rotated = VCamCopyRotated(fresh, shouldMirror, rot);
    CVPixelBufferRef src = rotated ? rotated : fresh;

    [gPhotoVTLock lock];
    OSStatus ts = VTPixelTransferSessionTransferImage(gPhotoTransferSession, src, dst);
    [gPhotoVTLock unlock];

    if (rotated) CVPixelBufferRelease(rotated);
    CVPixelBufferRelease(fresh);
    if (ts != noErr) {
        gRPhotoXferFail++;
        static BOOL logged = NO;
        if (!logged) { logged = YES; VCamLog(@"photo transfer failed (%d)", (int)ts); }
        return NO;
    }

    // Tag so downstream photo nodes skip re-overwriting this (or a derived) buffer.
    CMSetAttachment(sb, CFSTR("VCamTransitionID"), (__bridge CFTypeRef)@(1),
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
    [[VCamRTMPSource shared] ensureStarted];   // idempotent; keeps the RTMP puller alive
    CVImageBufferRef ib = sb ? CMSampleBufferGetImageBuffer(sb) : NULL;
    BOOL did = ib ? VCamOverwriteInPlace(ib) : NO;
    ((void (*)(id, SEL, CMSampleBufferRef))orig)(self, _cmd, sb);   // original sb, now overwritten

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
    if (sb) VCamOverwritePhotoInPlace(sb);
    ((void (*)(id, SEL, CMSampleBufferRef, id))orig)(self, _cmd, sb, input);
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

        // Start pulling immediately; frames only get used once enabled + fresh.
        [[VCamRTMPSource shared] ensureStarted];
        VCamLog(@"hooks installed (%lu emit, %lu photo)",
                (unsigned long)gEmitOrigs.count, (unsigned long)gRenderOrigs.count);
    }
}

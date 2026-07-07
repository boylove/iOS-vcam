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

// Still-photo replacement (report §2.3: the closed vcamera overwrites the photo
// path too, on the BWStillImageScalerNode / BWPhotoEncoderNode chain, with a
// TransitionID dedup mark) so the shutter captures OBS, not the real lens.
//
// ENABLED to match the original. An earlier attempt HUNG mediaserverd on the
// stock-Camera photo->video switch; the cause was our dedup using a PRIVATE
// attachment key. The original reuses CoreMedia's REAL
// kCMSampleBufferAttachmentKey_TransitionID — which the system itself stamps on
// the buffers it shuffles during a mode transition, so reading the real key makes
// us pass those through untouched instead of overwriting mid-transition (the
// hang). VCamOverwritePhotoInPlace now uses the real key, matching the original.
// Kill switch if a device still misbehaves: -DVCAM_HOOK_PHOTO_NODES=0 (falls back
// to real-lens stills; live video is unaffected).
#ifndef VCAM_HOOK_PHOTO_NODES
#define VCAM_HOOK_PHOTO_NODES 1
#endif

// AVCaptureDevicePosition: 0 unspecified, 1 back, 2 front. Updated from the
// FigCaptureSourceConfiguration -sourcePosition hook; read on the capture path.
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
// graph can service several source nodes concurrently. Rotation / front-camera
// mirror is layered on top with VTPixelRotationSession (see VCamCopyRotatedLocked).
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
        }
    });
}

// A single REUSED rotation-output buffer, keyed on (width, height, pixel format);
// reallocated only when those change. The closed vcamera rotates into ONE cached
// buffer (self+0x70) every frame, NOT a fresh pool buffer per frame — reusing the
// same IOSurface is part of why it never hits the GPU iofence deadlock (a new
// surface each frame lets the capture graph's GPU still be reading buffer N while
// we submit a write to buffer N+1, and the fences cross). See memory
// openvcam-original-gpu-sync-model / openvcam-freeze-gpu-iofence.
typedef struct { CVPixelBufferRef buf; size_t w, h; OSType fmt; } VCamRotBuf;

// Always-on failure-reason counters so the periodic health line reports WHY an
// overwrite was skipped (fail-open): no fresh decoded frame, no transfer session,
// or the VT transfer failed. Read in the health line; that is the reliable
// diagnostic (startup-gated debug logs fire before a syslog capture can attach).
static uint64_t gRNoFresh, gRNoXfer, gRXferFail;

// Return the cached rotation-output buffer, (re)allocating only when the geometry
// changes. NOT retained/returned to a pool per frame — the SAME buffer is handed
// back every call so the rotation writes into one stable IOSurface. The caller
// MUST already hold gVTLock (this touches shared cached state and is only ever
// called from inside the single rotate+transfer critical section).
static CVPixelBufferRef VCamRotBufGet(VCamRotBuf *p, size_t w, size_t h, OSType fmt) {
    if (!p->buf || p->w != w || p->h != h || p->fmt != fmt) {
        if (p->buf) { CVPixelBufferRelease(p->buf); p->buf = NULL; }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},   // VT needs IOSurface-backed buffers
        };
        CVPixelBufferRef nb = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt,
                                (__bridge CFDictionaryRef)attrs, &nb) == kCVReturnSuccess) {
            p->buf = nb; p->w = w; p->h = h; p->fmt = fmt;
        }
    }
    return p->buf;   // owned by the cache; caller does NOT release
}

// Rotation / front-camera mirror via VTPixelRotationSession (iOS 16+), matching
// the closed vcamera's _pixelRotationSession. Rotates + optionally horizontally
// flips the decoded frame into an intermediate buffer (source pixel format,
// rotated dimensions); the transfer session then scales/converts it to the
// camera format. Stored as CFTypeRef so the file-scope declaration needs no
// availability annotation; every use is inside `if (@available(iOS 16, *))`.
// On iOS < 16 rotation is skipped (the frame still shows, just unrotated).
static VCamRotBuf gRotBuf;
static CFTypeRef gRotationSession;   // VTPixelRotationSessionRef, or NULL

// Rotate `fresh` into the single cached rotation buffer and return it (NOT
// retained — owned by the cache, valid only until the next call). Returns NULL
// when no rotation/mirror is needed (caller transfers `fresh` directly) or on
// failure. The caller MUST already hold gVTLock: unlike before, this does NOT
// take the lock itself, so the rotate and the subsequent transfer run as ONE
// uninterrupted critical section (the closed vcamera holds a single lock across
// rotate+transfer; splitting them let a second emit thread interleave GPU
// submissions on the shared surfaces and cross the IOSurface fences -> deadlock).
static CVPixelBufferRef VCamCopyRotatedLocked(CVPixelBufferRef fresh, BOOL mirror, long rot,
                                              VCamRotBuf *rotBuf, CFTypeRef *sessionSlot) {
    if (!mirror && rot == 0) return NULL;          // nothing to do -> transfer 'fresh' directly
    CVPixelBufferRef rotated = NULL;
    if (@available(iOS 16.0, *)) {
        if (!*sessionSlot) {
            VTPixelRotationSessionRef rs = NULL;
            VTPixelRotationSessionCreate(kCFAllocatorDefault, &rs);
            *sessionSlot = rs;
        }
        VTPixelRotationSessionRef rs = (VTPixelRotationSessionRef)*sessionSlot;
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
            CVPixelBufferRef out = VCamRotBufGet(rotBuf, rw, rh, ffmt);  // cached, not retained
            if (out && VTPixelRotationSessionRotateImage(rs, fresh, out) == noErr) {
                rotated = out;
            }
        }
    }
    return rotated;   // cache-owned; caller must NOT release
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

    // Rotate + transfer as ONE atomic critical section under gVTLock — exactly
    // like the closed vcamera, which holds its single instance lock across the
    // WHOLE rotate->transfer sequence (self+0x18, disassembly 0x844a4..0x847d0).
    // The earlier code rotated under gVTLock, RELEASED it, then re-acquired it for
    // the transfer; in that gap another emit thread could interleave its own
    // rotate/transfer on the shared rotation buffer and camera surface, producing
    // the crossing GPU IOSurface fences (bug_type 284 iofence) that froze
    // mediaserverd. One unbroken lock span serialises all GPU submits on these
    // shared surfaces. VCamCopyRotatedLocked now REQUIRES the caller to hold gVTLock and
    // returns a CACHED buffer (not owned — do NOT release it).
    [gVTLock lock];
    CVPixelBufferRef rotated = VCamCopyRotatedLocked(fresh, shouldMirror, rot,
                                                     &gRotBuf, &gRotationSession);
    CVPixelBufferRef src = rotated ? rotated : fresh;
    size_t srcW = CVPixelBufferGetWidth(src), srcH = CVPixelBufferGetHeight(src);
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
// We reuse CoreMedia's real kCMSampleBufferAttachmentKey_TransitionID for the
// dedup mark, EXACTLY like the original — not a private key. This is deliberate:
// the system stamps TransitionID on the buffers it moves during a photo<->video
// mode switch, so reading the real key makes us skip those and pass through
// mid-transition (an earlier private-key version overwrote them and hung
// mediaserverd). The original also gates on a detected face (its beauty path); we
// replace unconditionally, which is what a virtual camera wants — the OBS frame
// lands in the photo whether or not a face is present.
// ---------------------------------------------------------------------------
// Counters stay unconditionally compiled: the always-on health line reads them so
// the syslog shows photo[...] = 0 when the photo path is disabled (the default).
static uint64_t gRPhotoNoFresh, gRPhotoDup, gRPhotoXferFail, gPhotoReplaced;

#if VCAM_HOOK_PHOTO_NODES
static VTPixelTransferSessionRef gPhotoTransferSession;
static NSLock *gPhotoVTLock;
// Photo path gets its OWN rotation session + reused rotation buffer, distinct from
// the live-video ones, so the two paths never touch each other's cached GPU state
// across their separate locks. Guarded by gPhotoVTLock (see VCamOverwritePhotoInPlace).
static CFTypeRef gPhotoRotationSession;   // VTPixelRotationSessionRef, or NULL
static VCamRotBuf gPhotoRotBuf;

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

    // Same geometry handling as the live path: a 4:3/16:9 landscape still buffer
    // needs the portrait OBS frame quarter-turned (auto-orient), then front-mirror,
    // so captured photos match the corrected video orientation instead of coming
    // out stretched/rotated.
    BOOL frontCamera = (gSourcePosition == 2);
    BOOL shouldMirror = cfg.mirror || (VCAM_FRONT_AUTOMIRROR && frontCamera);
    long rot = ((cfg.rotation % 360) + 360) % 360;
#if VCAM_AUTO_ORIENT
    if (VCamAutoOrientDegrees(fresh, dst) == 90) {
        rot = (rot + VCAM_AUTO_ORIENT_DIR) % 360;
    }
#endif
    // Same single-lock atomic rotate+transfer as the live path (see the long note
    // in VCamOverwriteInPlace): hold gPhotoVTLock across BOTH the rotate and the
    // transfer so no other thread interleaves a GPU submit on the shared photo
    // rotation buffer / still surface. Uses the photo path's OWN rotation buffer
    // and session (gPhotoRotBuf / gPhotoRotationSession) so it never contends the
    // video path's gRotBuf. VCamCopyRotatedLocked returns a CACHED buffer — do NOT
    // release it.
    [gPhotoVTLock lock];
    CVPixelBufferRef rotated = VCamCopyRotatedLocked(fresh, shouldMirror, rot,
                                                     &gPhotoRotBuf, &gPhotoRotationSession);
    CVPixelBufferRef src = rotated ? rotated : fresh;
    OSStatus ts = VTPixelTransferSessionTransferImage(gPhotoTransferSession, src, dst);
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
        VCamLog(@"hooks installed (%lu emit, %lu photo) VCAM_HOOK_PHOTO_NODES=%d",
                (unsigned long)gEmitOrigs.count, (unsigned long)gRenderOrigs.count,
                VCAM_HOOK_PHOTO_NODES);
    }
}

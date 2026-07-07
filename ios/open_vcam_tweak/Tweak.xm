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
// Replicates the closed com.x.vcamera approach: hook the terminal BufferWorks
// node `BWNodeOutput -emitSampleBuffer:` inside mediaserverd and SUBSTITUTE a
// brand-new sample buffer built from the decoded RTMP frame. We never mutate the
// camera's own CVPixelBuffer — the decoded frame is transferred (VTPixelTransfer
// + VTPixelRotation, camera pixel-format/size) into our own pool buffer, wrapped
// in a fresh CMSampleBuffer carrying the original timing/attachments, and passed
// to the original method. In-place overwrite (old CIContext path) was slow and
// crashed stock-Camera recording via the CMCapture PixelTransferSession
// assertion; substitution avoids both. Because mediaserverd sits below every
// app, this replaces the camera for all clients, including RootHide-patched apps
// (TikTok) that bypass normal app-level tweak injection.
//
// See memory: vcamera-mediaserverd-hookpoints; report: VCAMERA_REVERSE_REPORT.md.
// Fail-open everywhere; /var/mobile/vc.disabled or vc.plist enabled=false ->
// pure pass-through (never a black or frozen frame).
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
// Frame substitution (mirrors the closed vcamera's proven approach).
//
// We do NOT mutate the camera's shared CVPixelBuffer in place. Doing that is
// slow (the stock Camera routes a frame through several capture-graph nodes, so
// hooking them overwrote each frame multiple times) and, worse, trips the
// CMCapture PixelTransferSession assertion and crashes mediaserverd the moment
// the stock Camera records (EXECUTION-PLAN §4.6). The closed vcamera instead
// renders its frame into its OWN pool buffer and emits a brand-new sample
// buffer downstream, never touching the camera's buffer — so it neither lags
// nor crashes. We do the same: render the decoded RTMP frame into a pool buffer
// matching the camera buffer, wrap it in a fresh CMSampleBuffer carrying the
// original timing + attachments, and hand that to the original method.
// ---------------------------------------------------------------------------
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
// those change. Used for the substitute buffers handed to the capture graph.
typedef struct { CVPixelBufferPoolRef pool; size_t w, h; OSType fmt; } VCamPool;
static VCamPool gOutPool;

// Always-on failure-reason counters so the periodic health line reports WHY a
// replacement returned NULL (fail-open) — the startup-gated debug logs fire
// before a syslog capture can attach, so these are the reliable diagnostic.
static uint64_t gRNoFresh, gRNoXfer, gRNoPool, gRXferFail, gRNoSB;

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

// Transfers the latest decoded frame (scaled + pixel-format converted) into a
// fresh pool buffer matching `templatePB`. Returns a retained buffer, or NULL
// when there is no fresh frame (caller then passes the real camera frame through).
static CVPixelBufferRef VCamCopyReplacementBuffer(CVImageBufferRef templatePB) {
    if (!templatePB) return NULL;
    VCamConfig *cfg = [VCamConfig shared];
    if (!cfg.enabled) return NULL;

    CVPixelBufferRef fresh = [[VCamFrameStore shared] copyFreshFrameWithMaxAge:kVCamFrameMaxAge];
    if (!fresh) { gRNoFresh++; return NULL; }             // stale/no stream -> real camera

    VCamEnsureSessions();
    if (!gTransferSession) { gRNoXfer++; CVPixelBufferRelease(fresh); return NULL; }

    size_t w = CVPixelBufferGetWidth(templatePB);
    size_t h = CVPixelBufferGetHeight(templatePB);
    OSType fmt = CVPixelBufferGetPixelFormatType(templatePB);

    CVPixelBufferRef out = VCamPoolCopy(&gOutPool, w, h, fmt);
    if (!out) { gRNoPool++; CVPixelBufferRelease(fresh); return NULL; }

    // Rotate / mirror first (front camera auto-mirrors; config files are
    // unreadable in mediaserverd so mirror is driven by the sourcePosition hook),
    // then scale + pixel-format/range convert into the camera-format buffer.
    BOOL frontCamera = (gSourcePosition == 2);
    BOOL shouldMirror = cfg.mirror || (VCAM_FRONT_AUTOMIRROR && frontCamera);
    long rot = ((cfg.rotation % 360) + 360) % 360;
    CVPixelBufferRef rotated = VCamCopyRotated(fresh, shouldMirror, rot);
    CVPixelBufferRef src = rotated ? rotated : fresh;

    [gVTLock lock];
    OSStatus ts = VTPixelTransferSessionTransferImage(gTransferSession, src, out);
    [gVTLock unlock];

#if VCAM_DEBUG
    { static int d = 0; if (d < 12) { d++;
        VCamDebugLog(@"repl: srcW=%zu srcH=%zu camW=%zu camH=%zu camFmt=%c%c%c%c out=%p ts=%d",
                     CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), w, h,
                     (char)(fmt>>24),(char)(fmt>>16),(char)(fmt>>8),(char)fmt, out, (int)ts); } }
#endif

    // Copy the camera buffer's colour attachments (YCbCr matrix, primaries,
    // transfer function, clean aperture, ...) onto our buffer so downstream and
    // the graph teardown treat it identically to a real camera frame.
    CFDictionaryRef att = CVBufferCopyAttachments(templatePB, kCVAttachmentMode_ShouldPropagate);
    if (att) {
        CVBufferSetAttachments(out, att, kCVAttachmentMode_ShouldPropagate);
        CFRelease(att);
    }

    if (rotated) CVPixelBufferRelease(rotated);
    CVPixelBufferRelease(fresh);
    if (ts != noErr) {
        gRXferFail++;
        static BOOL logged = NO;
        if (!logged) { logged = YES; VCamLog(@"transfer failed (%d) src=%zux%zu dst=%zux%zu dstFmt=%c%c%c%c",
                                              (int)ts, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src),
                                              w, h, (char)(fmt>>24),(char)(fmt>>16),(char)(fmt>>8),(char)fmt); }
        CVPixelBufferRelease(out);
        return NULL;
    }
    return out;
}

// Builds a replacement CMSampleBuffer (fresh frame + original timing/attachments)
// or NULL. Caller passes it to the original method and then CFReleases it.
static CMSampleBufferRef VCamCreateReplacementSampleBuffer(CMSampleBufferRef origSB) {
    CVImageBufferRef origPB = CMSampleBufferGetImageBuffer(origSB);
    if (!origPB) return NULL;

    CVPixelBufferRef out = VCamCopyReplacementBuffer(origPB);
    if (!out) return NULL;

    [[VCamRTMPSource shared] ensureStarted];

    // Reuse the camera sample buffer's OWN format description. Our buffer has the
    // identical pixel format + dimensions (the transfer target came from origPB),
    // so the description matches. A description created afresh from our buffer
    // differs subtly and made -[BWGraph stop:] assert on capture teardown;
    // reusing the original makes our frame indistinguishable from the camera's.
    // Create the format description FRESH from our own buffer. CMSampleBufferCreate‐
    // ForImageBuffer requires the description to match the image buffer exactly;
    // reusing the camera sample buffer's description (which carries format
    // extensions our pool buffer lacks) makes creation FAIL — that was the noSB
    // failure. The closed vcamera also creates its description from its own buffer.
    CMVideoFormatDescriptionRef fd = NULL;
    BOOL ownFd = NO;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, out, &fd) == noErr && fd) {
        ownFd = YES;
    } else {
        fd = (CMVideoFormatDescriptionRef)CMSampleBufferGetFormatDescription(origSB);  // fallback
    }

    CMSampleBufferRef newSB = NULL;
    OSStatus s = -1;
    if (fd) {
        CMSampleTimingInfo timing;
        if (CMSampleBufferGetSampleTimingInfo(origSB, 0, &timing) != noErr) {
            timing.duration = kCMTimeInvalid;
            timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(origSB);
            timing.decodeTimeStamp = kCMTimeInvalid;
        }
        s = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, out, true, NULL, NULL,
                                               fd, &timing, &newSB);
    }
    if (ownFd && fd) CFRelease(fd);
    CVPixelBufferRelease(out);
    if (s != noErr || !newSB) {
        gRNoSB++;
        static BOOL logged = NO;
        if (!logged) { logged = YES; VCamLog(@"sampleBuffer create failed (%d) fd=%p", (int)s, fd); }
        return NULL;
    }

    // Propagate the per-sample attachments (orientation / dependency flags etc.)
    // so downstream treats our frame exactly like the camera's.
    CFArrayRef src = CMSampleBufferGetSampleAttachmentsArray(origSB, false);
    if (src && CFArrayGetCount(src) > 0) {
        CFArrayRef dst = CMSampleBufferGetSampleAttachmentsArray(newSB, true);
        if (dst && CFArrayGetCount(dst) > 0) {
            CFDictionaryRef s0 = (CFDictionaryRef)CFArrayGetValueAtIndex(src, 0);
            CFMutableDictionaryRef d0 = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(dst, 0);
            if (s0 && d0) {
                CFIndex n = CFDictionaryGetCount(s0);
                if (n > 0) {
                    const void **keys = (const void **)malloc(sizeof(void *) * (size_t)n);
                    const void **vals = (const void **)malloc(sizeof(void *) * (size_t)n);
                    if (keys && vals) {
                        CFDictionaryGetKeysAndValues(s0, keys, vals);
                        for (CFIndex i = 0; i < n; i++) CFDictionarySetValue(d0, keys[i], vals[i]);
                    }
                    free(keys); free(vals);
                }
            }
        }
    }
    return newSB;
}

// ---------------------------------------------------------------------------
// Hook plumbing for private mediaserverd classes (objc_getClass + MSHookMessageEx)
// ---------------------------------------------------------------------------
static NSMutableDictionary<NSValue *, NSValue *> *gEmitOrigs;    // Class -> IMP
static NSMutableDictionary<NSValue *, NSValue *> *gRenderOrigs;  // Class -> IMP

static IMP VCamFindOrig(NSMutableDictionary<NSValue *, NSValue *> *map, id obj) {
    Class c = object_getClass(obj);
    while (c) {
        NSValue *v = map[[NSValue valueWithPointer:(__bridge void *)c]];
        if (v) return (IMP)[v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

// -[... emitSampleBuffer:] — substitute a fresh sample buffer, never mutate sb.
static void VCamEmit(id self, SEL _cmd, CMSampleBufferRef sb) {
    IMP orig = VCamFindOrig(gEmitOrigs, self);
    if (!orig) return;
    CMSampleBufferRef rep = (sb && CMSampleBufferGetImageBuffer(sb))
                                ? VCamCreateReplacementSampleBuffer(sb) : NULL;
    ((void (*)(id, SEL, CMSampleBufferRef))orig)(self, _cmd, rep ?: sb);
    if (rep) CFRelease(rep);

    // Lightweight always-on health line (release builds are otherwise silent once
    // running): every ~600 emits report how many frames we actually replaced, so
    // "OBS not showing" can be told apart from "decoder idle / fail-open" from the
    // syslog alone. Logs the FIRST replacement immediately so success is visible.
    static uint64_t calls = 0, repl = 0;
    calls++;
    if (rep) {
        repl++;
        if (repl == 1) VCamLog(@"health: first frame replaced (OBS is live)");
    }
    if ((calls % 600) == 0)
        VCamLog(@"health: emits=%llu replaced=%llu why[noFresh=%llu noXfer=%llu noPool=%llu xferFail=%llu noSB=%llu]",
                calls, repl, gRNoFresh, gRNoXfer, gRNoPool, gRXferFail, gRNoSB);
}

// -[... renderSampleBuffer:forInput:] — only installed when VCAM_HOOK_RENDER_NODES
// is set (off by default; emit-only is enough and avoids the record-path crash).
__attribute__((unused))
static void VCamRender(id self, SEL _cmd, CMSampleBufferRef sb, id input) {
    IMP orig = VCamFindOrig(gRenderOrigs, self);
    if (!orig) return;
    CMSampleBufferRef rep = (sb && CMSampleBufferGetImageBuffer(sb))
                                ? VCamCreateReplacementSampleBuffer(sb) : NULL;
    ((void (*)(id, SEL, CMSampleBufferRef, id))orig)(self, _cmd, rep ?: sb, input);
    if (rep) CFRelease(rep);
}

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
        gRenderOrigs = [NSMutableDictionary dictionary];

        VCamConfig *cfg = [VCamConfig shared];
        VCamLog(@"loading in mediaserverd, enabled=%d url=%@", cfg.enabled, cfg.rtmpURL);

        SEL emitSel = @selector(emitSampleBuffer:);

        // Terminal emit path only. This is the single point where a node emits
        // its finished frame to every downstream consumer (preview AND the movie
        // recorder), so overwriting here replaces the frame for all of them with
        // exactly ONE CIContext render per frame.
        //
        // We deliberately do NOT hook the intermediate renderSampleBuffer: nodes
        // (BWNode/BWUBNode/BWPixelTransferNode) any more:
        //   * The stock Camera routes each frame through several of them, so
        //     hooking them overwrote the same frame 3-4x/frame -> GPU-bound,
        //     choppy preview.
        //   * BWPixelTransferNode is the recording-path format/resolution
        //     converter; overwriting its buffer trips the CMCapture
        //     PixelTransferSession assertion and crashes mediaserverd the moment
        //     the stock Camera switches to video/record (EXECUTION-PLAN §4.6).
        // Set VCAM_HOOK_RENDER_NODES=1 to restore the old behaviour for testing.
        VCamHook("BWNodeOutput", emitSel, (IMP)VCamEmit, gEmitOrigs);

#ifndef VCAM_HOOK_RENDER_NODES
#define VCAM_HOOK_RENDER_NODES 0
#endif
#if VCAM_HOOK_RENDER_NODES
        SEL renderSel = @selector(renderSampleBuffer:forInput:);
        const char *renderClasses[] = { "BWNode", "BWUBNode", "BWPixelTransferNode" };
        for (size_t i = 0; i < sizeof(renderClasses) / sizeof(renderClasses[0]); i++) {
            VCamHook(renderClasses[i], renderSel, (IMP)VCamRender, gRenderOrigs);
        }
#endif

        // Front/back detection for auto-mirror (config files unreadable here).
        VCamHookSourcePosition();

        // Start pulling immediately; frames only get used once enabled + fresh.
        [[VCamRTMPSource shared] ensureStarted];
        VCamLog(@"hooks installed (%lu emit, %lu render)",
                (unsigned long)gEmitOrigs.count, (unsigned long)gRenderOrigs.count);
    }
}

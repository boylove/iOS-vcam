#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
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
// Replicates the closed com.x.vcamera approach: hook the private BufferWorks
// (BW*) capture-graph classes inside mediaserverd and overwrite the camera
// pixel buffer IN PLACE with the decoded RTMP frame. Because mediaserverd sits
// below every app, this replaces the camera for all clients, including
// RootHide-patched apps (TikTok) that bypass normal app-level tweak injection.
//
// See memory: vcamera-mediaserverd-hookpoints.
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
static CIContext *VCamCIContext(void) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            ctx = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @NO }];
        } @catch (__unused NSException *e) { ctx = nil; }
    });
    return ctx;
}

// Pool of replacement pixel buffers, matching the current camera buffer's pixel
// format + dimensions (recreated only when those change).
static CVPixelBufferPoolRef gPool;
static size_t gPoolW, gPoolH;
static OSType gPoolFmt;

static CVPixelBufferRef VCamCopyPoolBuffer(size_t w, size_t h, OSType fmt) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });

    CVPixelBufferRef out = NULL;
    [lock lock];
    if (!gPool || gPoolW != w || gPoolH != h || gPoolFmt != fmt) {
        if (gPool) { CVPixelBufferPoolRelease(gPool); gPool = NULL; }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey       : @(fmt),
            (id)kCVPixelBufferWidthKey                 : @(w),
            (id)kCVPixelBufferHeightKey                : @(h),
            (id)kCVPixelBufferIOSurfacePropertiesKey   : @{},
            (id)kCVPixelBufferMetalCompatibilityKey    : @YES,  // let the GPU CIContext render into it
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                (__bridge CFDictionaryRef)attrs, &gPool);
        gPoolW = w; gPoolH = h; gPoolFmt = fmt;
    }
    if (gPool) CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, gPool, &out);
    [lock unlock];
    return out;
}

#if VCAM_DEBUG
// Sample the centre byte of plane 0 (luma for YCbCr, blue for BGRA) so we can
// tell whether a buffer actually holds an image or is all-black.
static int VCamCenterByte(CVPixelBufferRef pb) {
    if (!pb) return -3;
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return -2;
    int v = -1;
    if (CVPixelBufferIsPlanar(pb)) {
        uint8_t *b = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
        size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
        size_t h = CVPixelBufferGetHeightOfPlane(pb, 0), w = CVPixelBufferGetWidthOfPlane(pb, 0);
        if (b) v = b[(h / 2) * bpr + (w / 2)];
    } else {
        uint8_t *b = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        size_t h = CVPixelBufferGetHeight(pb), w = CVPixelBufferGetWidth(pb);
        if (b) v = b[(h / 2) * bpr + (w / 2) * 4];
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return v;
}
#endif

// Renders the latest decoded frame (scaled/mirrored/rotated) into a fresh pool
// buffer matching `templatePB`. Returns a retained buffer, or NULL when there
// is no fresh frame (caller then passes the real camera frame through).
static CVPixelBufferRef VCamCopyReplacementBuffer(CVImageBufferRef templatePB) {
    if (!templatePB) return NULL;
    VCamConfig *cfg = [VCamConfig shared];
    if (!cfg.enabled) return NULL;

    CVPixelBufferRef fresh = [[VCamFrameStore shared] copyFreshFrameWithMaxAge:kVCamFrameMaxAge];
    if (!fresh) return NULL;                              // stale/no stream -> real camera

    CIContext *ctx = VCamCIContext();
    if (!ctx) { CVPixelBufferRelease(fresh); return NULL; }

    size_t w = CVPixelBufferGetWidth(templatePB);
    size_t h = CVPixelBufferGetHeight(templatePB);
    OSType fmt = CVPixelBufferGetPixelFormatType(templatePB);

    CVPixelBufferRef out = VCamCopyPoolBuffer(w, h, fmt);
    if (!out) { CVPixelBufferRelease(fresh); return NULL; }

    // Propagate the camera buffer's color attachments (YCbCr matrix, colour
    // primaries, transfer function, clean aperture, ...) onto our buffer. A
    // fresh YCbCr buffer with no colour info renders BLACK downstream, so this
    // is essential for the substituted frame to display correctly.
    CFDictionaryRef att = CVBufferCopyAttachments(templatePB, kCVAttachmentMode_ShouldPropagate);
    if (att) {
        CVBufferSetAttachments(out, att, kCVAttachmentMode_ShouldPropagate);
        CFRelease(att);
    }

    BOOL ok = NO;
    @try {
        @autoreleasepool {
            CIImage *img = [CIImage imageWithCVPixelBuffer:fresh];

            // Mirror on the front camera automatically (config files are
            // unreadable in mediaserverd), OR-ed with any explicit cfg.mirror.
            BOOL frontCamera = (gSourcePosition == 2);
            BOOL shouldMirror = cfg.mirror || (VCAM_FRONT_AUTOMIRROR && frontCamera);

            CGAffineTransform t = CGAffineTransformIdentity;
            if (shouldMirror) t = CGAffineTransformScale(t, -1, 1);
            if (cfg.rotation) t = CGAffineTransformRotate(t, -(CGFloat)cfg.rotation * M_PI / 180.0);
            img = [img imageByApplyingTransform:t];
            img = [img imageByApplyingTransform:
                       CGAffineTransformMakeTranslation(-img.extent.origin.x, -img.extent.origin.y)];

            CGFloat sx = (CGFloat)w / img.extent.size.width;
            CGFloat sy = (CGFloat)h / img.extent.size.height;
            img = [img imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
            img = [img imageByApplyingTransform:
                       CGAffineTransformMakeTranslation(-img.extent.origin.x, -img.extent.origin.y)];

            [ctx render:img toCVPixelBuffer:out bounds:CGRectMake(0, 0, w, h) colorSpace:NULL];
            ok = YES;
        }
    } @catch (__unused NSException *e) { ok = NO; }

#if VCAM_DEBUG
    static int dbg = 0;
    if (dbg < 5) {
        dbg++;
        VCamDebugLog(@"repl: camFmt=%c%c%c%c w=%zu h=%zu renderOK=%d "
                     @"freshCenter=%d outCenter=%d camCenter=%d",
                     (char)(fmt >> 24), (char)(fmt >> 16), (char)(fmt >> 8), (char)fmt,
                     w, h, ok, VCamCenterByte(fresh), VCamCenterByte(out),
                     VCamCenterByte(templatePB));
    }
#endif

    CVPixelBufferRelease(fresh);
    if (!ok) { CVPixelBufferRelease(out); return NULL; }
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

    CMSampleBufferRef newSB = NULL;
    CMVideoFormatDescriptionRef fd = NULL;
    OSStatus s = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, out, &fd);
    if (s == noErr && fd) {
        CMSampleTimingInfo timing;
        if (CMSampleBufferGetSampleTimingInfo(origSB, 0, &timing) != noErr) {
            timing.duration = kCMTimeInvalid;
            timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(origSB);
            timing.decodeTimeStamp = kCMTimeInvalid;
        }
        s = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, out, true, NULL, NULL,
                                               fd, &timing, &newSB);
    }
    if (fd) CFRelease(fd);
    CVPixelBufferRelease(out);
#if VCAM_DEBUG
    static int dbg2 = 0;
    if (dbg2 < 5) { dbg2++; VCamDebugLog(@"repl: sampleBufferStatus=%d newSB=%p", (int)s, newSB); }
#endif
    if (s != noErr || !newSB) return NULL;

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
#if VCAM_DEBUG
    static uint64_t calls = 0, repl = 0;
    calls++; if (rep) repl++;
    if ((calls % 120) == 0) VCamDebugLog(@"stats: emits=%llu replaced=%llu", calls, repl);
#endif
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

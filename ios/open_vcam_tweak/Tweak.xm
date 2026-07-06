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
// In-place frame overwrite
//
// Renders the latest decoded frame (scaled/mirrored/rotated) directly into the
// camera's existing CVPixelBuffer, so pixel format, dimensions, IOSurface
// backing and attachments are all preserved. Returns YES if it overwrote.
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

static BOOL VCamOverwriteImageBuffer(CVImageBufferRef pb) {
    if (!pb) return NO;
    VCamConfig *cfg = [VCamConfig shared];
    if (!cfg.enabled) return NO;

    CVPixelBufferRef fresh = [[VCamFrameStore shared] copyFreshFrameWithMaxAge:kVCamFrameMaxAge];
    if (!fresh) return NO;                              // stale/no stream -> real camera

    CIContext *ctx = VCamCIContext();
    if (!ctx) { CVPixelBufferRelease(fresh); return NO; }

    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);
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

            [ctx render:img toCVPixelBuffer:pb bounds:CGRectMake(0, 0, w, h) colorSpace:NULL];
            ok = YES;
        }
    } @catch (__unused NSException *e) { ok = NO; }

    CVPixelBufferRelease(fresh);
    return ok;
}

static void VCamReplaceSampleBuffer(CMSampleBufferRef sb) {
    if (!sb) return;
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;                                   // audio/metadata -> skip

    BOOL did = VCamOverwriteImageBuffer(pb);
    if (did) [[VCamRTMPSource shared] ensureStarted];
#if VCAM_DEBUG
    static uint64_t calls = 0, overwrote = 0;
    calls++;
    if (did) overwrote++;
    if ((calls % 120) == 0) {
        VCamDebugLog(@"stats: videoBuffers=%llu overwrote=%llu (fresh frames %@)",
                     calls, overwrote, overwrote ? @"present" : @"MISSING");
    }
#endif
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

// -[... emitSampleBuffer:]
static void VCamEmit(id self, SEL _cmd, CMSampleBufferRef sb) {
    IMP orig = VCamFindOrig(gEmitOrigs, self);
    if (!orig) return;
    VCamReplaceSampleBuffer(sb);
    ((void (*)(id, SEL, CMSampleBufferRef))orig)(self, _cmd, sb);
}

// -[... renderSampleBuffer:forInput:]
static void VCamRender(id self, SEL _cmd, CMSampleBufferRef sb, id input) {
    IMP orig = VCamFindOrig(gRenderOrigs, self);
    if (!orig) return;
    VCamReplaceSampleBuffer(sb);
    ((void (*)(id, SEL, CMSampleBufferRef, id))orig)(self, _cmd, sb, input);
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
        SEL renderSel = @selector(renderSampleBuffer:forInput:);

        // Terminal emit path.
        VCamHook("BWNodeOutput", emitSel, (IMP)VCamEmit, gEmitOrigs);

        // Video-carrying render nodes only (metadata/orientation nodes skipped
        // to minimise pipeline interference).
        const char *renderClasses[] = {
            "BWNode", "BWUBNode", "BWPixelTransferNode",
        };
        for (size_t i = 0; i < sizeof(renderClasses) / sizeof(renderClasses[0]); i++) {
            VCamHook(renderClasses[i], renderSel, (IMP)VCamRender, gRenderOrigs);
        }

        // Front/back detection for auto-mirror (config files unreadable here).
        VCamHookSourcePosition();

        // Start pulling immediately; frames only get used once enabled + fresh.
        [[VCamRTMPSource shared] ensureStarted];
        VCamLog(@"hooks installed (%lu emit, %lu render)",
                (unsigned long)gEmitOrigs.count, (unsigned long)gRenderOrigs.count);
    }
}

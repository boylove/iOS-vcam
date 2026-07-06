#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
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

// ---------------------------------------------------------------------------
// Logging (shared with the other modules via extern VCamLog)
// ---------------------------------------------------------------------------
#define VCAM_LOG_NAME @"OpenVCam.log"

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

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = VCamLogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:NO];
    } else {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        }
    }
}

// ---------------------------------------------------------------------------
// Frame replacement: build a camera-shaped CMSampleBuffer from the latest
// decoded RTMP frame, matching the original's dimensions / pixel format /
// timing. Fail-open: any problem returns NULL and the caller uses the real
// frame, so a dead stream never blacks out the preview.
// ---------------------------------------------------------------------------
static const NSTimeInterval kVCamFrameMaxAge = 0.5;   // watchdog: 500ms

static CIContext *VCamCIContext(void) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctx = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @NO }];
    });
    return ctx;
}

// Pool cache keyed by width/height/format so we don't reallocate per frame.
static CVPixelBufferPoolRef gPool = NULL;
static size_t gPoolW = 0, gPoolH = 0;
static OSType gPoolFmt = 0;
static NSLock *gPoolLock;

static CVPixelBufferRef VCamDequeueDest(size_t w, size_t h, OSType fmt) CF_RETURNS_RETAINED {
    [gPoolLock lock];
    if (!gPool || gPoolW != w || gPoolH != h || gPoolFmt != fmt) {
        if (gPool) { CVPixelBufferPoolRelease(gPool); gPool = NULL; }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
            (id)kCVPixelBufferWidthKey: @(w),
            (id)kCVPixelBufferHeightKey: @(h),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                (__bridge CFDictionaryRef)attrs, &gPool);
        gPoolW = w; gPoolH = h; gPoolFmt = fmt;
    }
    CVPixelBufferRef dest = NULL;
    if (gPool) CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, gPool, &dest);
    [gPoolLock unlock];
    return dest;
}

static CMSampleBufferRef VCamMakeReplacement(CMSampleBufferRef orig) CF_RETURNS_RETAINED {
    CVImageBufferRef origPB = CMSampleBufferGetImageBuffer(orig);
    if (!origPB) return NULL;                       // audio / non-image → pass through

    CVPixelBufferRef fresh = [[VCamFrameStore shared] copyFreshFrameWithMaxAge:kVCamFrameMaxAge];
    if (!fresh) return NULL;                        // stale/no stream → real camera

    size_t w = CVPixelBufferGetWidth(origPB);
    size_t h = CVPixelBufferGetHeight(origPB);
    OSType fmt = CVPixelBufferGetPixelFormatType(origPB);

    CVPixelBufferRef dest = VCamDequeueDest(w, h, fmt);
    if (!dest) { CVPixelBufferRelease(fresh); return NULL; }

    VCamConfig *cfg = [VCamConfig shared];

    @autoreleasepool {
        CIImage *img = [CIImage imageWithCVPixelBuffer:fresh];

        CGAffineTransform t = CGAffineTransformIdentity;
        if (cfg.mirror) t = CGAffineTransformScale(t, -1, 1);
        if (cfg.rotation) t = CGAffineTransformRotate(t, -(CGFloat)cfg.rotation * M_PI / 180.0);
        img = [img imageByApplyingTransform:t];
        img = [img imageByApplyingTransform:
                   CGAffineTransformMakeTranslation(-img.extent.origin.x, -img.extent.origin.y)];

        CGFloat sx = (CGFloat)w / img.extent.size.width;
        CGFloat sy = (CGFloat)h / img.extent.size.height;
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
        img = [img imageByApplyingTransform:
                   CGAffineTransformMakeTranslation(-img.extent.origin.x, -img.extent.origin.y)];

        [VCamCIContext() render:img
               toCVPixelBuffer:dest
                        bounds:CGRectMake(0, 0, w, h)
                    colorSpace:NULL];
    }
    CVPixelBufferRelease(fresh);

    CMVideoFormatDescriptionRef fmtDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault, dest, &fmtDesc);
    if (status != noErr || !fmtDesc) {
        CVPixelBufferRelease(dest);
        return NULL;
    }

    CMSampleTimingInfo timing;
    if (CMSampleBufferGetSampleTimingInfo(orig, 0, &timing) != noErr) {
        timing.duration = kCMTimeInvalid;
        timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(orig);
        timing.decodeTimeStamp = kCMTimeInvalid;
    }

    CMSampleBufferRef replacement = NULL;
    status = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault, dest, fmtDesc, &timing, &replacement);

    CFRelease(fmtDesc);
    CVPixelBufferRelease(dest);

    if (status != noErr) return NULL;
    return replacement;
}

// ---------------------------------------------------------------------------
// Delegate hooking (mirrors the proven audio-bridge approach)
// ---------------------------------------------------------------------------
static NSMutableDictionary<NSString *, NSValue *> *gOriginalIMPs;
static NSMutableSet<NSString *> *gHookedClasses;
static NSLock *gHookLock;

static IMP VCamOriginalIMPForObject(id object) {
    NSString *className = NSStringFromClass(object_getClass(object));
    NSValue *value = gOriginalIMPs[className];
    return value ? [value pointerValue] : NULL;
}

static void VCamDidOutput(id self, SEL _cmd, id output,
                          CMSampleBufferRef sampleBuffer, id connection) {
    IMP original = VCamOriginalIMPForObject(self);
    if (!original) return;

    CMSampleBufferRef toSend = sampleBuffer;
    CMSampleBufferRef replacement = NULL;

    if ([VCamConfig shared].enabled) {
        replacement = VCamMakeReplacement(sampleBuffer);
        if (replacement) toSend = replacement;
    }

    ((void (*)(id, SEL, id, CMSampleBufferRef, id))original)(self, _cmd, output, toSend, connection);

    if (replacement) CFRelease(replacement);
}

static void VCamHookDelegateIfNeeded(id delegate) {
    if (!delegate) return;

    VCamConfig *cfg = [VCamConfig shared];
    [cfg reloadNow];
    if (!cfg.enabled) return;

    Class cls = object_getClass(delegate);
    if (!cls) return;

    SEL selector = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    if (!class_getInstanceMethod(cls, selector)) return;

    NSString *className = NSStringFromClass(cls);
    [gHookLock lock];
    if (![gHookedClasses containsObject:className]) {
        IMP original = NULL;
        MSHookMessageEx(cls, selector, (IMP)VCamDidOutput, &original);
        if (original) {
            gOriginalIMPs[className] = [NSValue valueWithPointer:original];
            [gHookedClasses addObject:className];
            VCamLog(@"hooked video delegate %@", className);
        }
    }
    [gHookLock unlock];

    // Only now (camera actually in use) start pulling the stream.
    [[VCamRTMPSource shared] ensureStarted];
}

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)sampleBufferDelegate
                          queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    VCamHookDelegateIfNeeded(sampleBufferDelegate);
    %orig(sampleBufferDelegate, sampleBufferCallbackQueue);
}

%end

// ---------------------------------------------------------------------------
// #pragma mark - Audio (Phase 3 placeholder)
// The verified AudioUnitRender / AVCaptureAudioDataOutput replacement logic
// from ios/audio_bridge_safe_tweak/Tweak.x will be merged here so a single
// dylib serves both video and audio under the same vc.plist config and kill
// switch. Intentionally not implemented in this video-first build.
// ---------------------------------------------------------------------------

%ctor {
    @autoreleasepool {
        gOriginalIMPs = [NSMutableDictionary dictionary];
        gHookedClasses = [NSMutableSet set];
        gHookLock = [[NSLock alloc] init];
        gPoolLock = [[NSLock alloc] init];

        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *procName = [[NSProcessInfo processInfo] processName] ?: @"";
        VCamConfig *cfg = [VCamConfig shared];
        VCamLog(@"loaded bundle=%@ process=%@ enabled=%d url=%@",
                bundleID, procName, cfg.enabled, cfg.rtmpURL);
        // RTMP pull is started lazily when a camera delegate is set.
    }
}

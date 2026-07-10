#import "VCamFrameStore.h"
#import <VideoToolbox/VideoToolbox.h>
#import <time.h>

// VCAM_GPU_ACCEL default (0 = CPU) mirrors Tweak.xm. The original configures its rotation
// session GPU-accelerated (init 0x82650); we currently use the device-stable CPU path
// (0.6.3) for BOTH the transfer and this rotation, kept consistent here. (The GPU-vs-CPU
// fidelity is a separate step.)
#ifndef VCAM_GPU_ACCEL
#define VCAM_GPU_ACCEL 0
#endif

@implementation VCamFrameStore {
    CVPixelBufferRef _raw;                   // raw decoded frame        (== engine ivar 0x50)
    CVPixelBufferRef _rotated;               // CCW90 pre-rotated copy   (== engine ivar 0x70)
    VTPixelRotationSessionRef _rotSession;   // CCW90 rotation session   (== engine ivar 0x98)
    NSTimeInterval _updatedAt;
    NSRecursiveLock *_lock;                  // THE single engine lock   (== engine ivar 0x18)
}

+ (instancetype)shared {
    static VCamFrameStore *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[VCamFrameStore alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _raw = NULL;
        _rotated = NULL;
        _rotSession = NULL;
        _updatedAt = 0;
        // NSRecursiveLock, matching the closed vcamera's engine _lock (0x823f8) — the ingest
        // rotate and the emit transfer share it, and it can re-enter without self-deadlock.
        _lock = [[NSRecursiveLock alloc] init];
    }
    return self;
}

- (void)dealloc {
    if (_raw) CVPixelBufferRelease(_raw);
    if (_rotated) CVPixelBufferRelease(_rotated);
    if (_rotSession) {
        // _rotSession is only ever created inside the iOS 16 @available block below, so a
        // non-NULL value means we are on iOS 16+; the guard is for the compiler.
        if (@available(iOS 16.0, *)) {
            VTPixelRotationSessionInvalidate((VTPixelRotationSessionRef)_rotSession);
        }
        CFRelease(_rotSession);
    }
}

static NSTimeInterval VCamNow(void) {
    // Monotonic seconds; avoids wall-clock jumps.
    return (NSTimeInterval)clock_gettime_nsec_np(CLOCK_MONOTONIC) / (NSTimeInterval)NSEC_PER_SEC;
}

// Faithful port of the closed vcamera's `create90ImageBuffer:` (0x829e0): CCW90-rotate
// `src` into a FRESH buffer with swapped W/H, whose IOSurface uses exactly
// { IOSurfacePreallocPages:0, IOSurfacePurgeWhenNotInUse:1 } (RE 0x82a74-0x82af0, key
// strings 0x10ee88/0x10eea8). A fresh buffer every frame — like the original's per-call
// CVPixelBufferCreate — so the NEXT frame's rotation can never alias the buffer the emit is
// mid-transfer on. Caller MUST hold _lock. Returns a +1 buffer, or NULL on failure.
- (CVPixelBufferRef)create90Locked:(CVPixelBufferRef)src CF_RETURNS_RETAINED {
    if (!src) return NULL;
    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);
    OSType fmt = CVPixelBufferGetPixelFormatType(src);
    if (w == 0 || h == 0) return NULL;

    // VTPixelRotationSession is iOS 16+ (the tweak's real target is iOS 16 mediaserverd).
    if (@available(iOS 16.0, *)) {
        if (!_rotSession) {
            VTPixelRotationSessionRef rs = NULL;
            if (VTPixelRotationSessionCreate(kCFAllocatorDefault, &rs) != noErr || !rs) return NULL;
            // Config == engine init (0x82650): (GPU-accel) + Rotation = CCW90. No flip — the
            // camera-overwrite path always rotates CCW90 for BOTH cameras; the front-camera
            // selfie mirror is done by the downstream capture pipeline, not here.
            VTSessionSetProperty(rs, (__bridge CFStringRef)@"EnableGPUAcceleratedTransfer",
                                 VCAM_GPU_ACCEL ? kCFBooleanTrue : kCFBooleanFalse);
            VTSessionSetProperty(rs, kVTPixelRotationPropertyKey_Rotation, kVTRotation_CCW90);
            _rotSession = rs;
        }

        NSDictionary *ioSurface = @{
            (__bridge id)CFSTR("IOSurfacePreallocPages")     : @0,
            (__bridge id)CFSTR("IOSurfacePurgeWhenNotInUse") : @1,
        };
        NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : ioSurface };

        CVPixelBufferRef dst = NULL;
        // Swapped W/H for the quarter turn (0x82af4: CVPixelBufferCreate width=srcH, height=srcW).
        if (CVPixelBufferCreate(kCFAllocatorDefault, h, w, fmt,
                                (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess || !dst) {
            return NULL;
        }
        if (VTPixelRotationSessionRotateImage(_rotSession, src, dst) != noErr) {
            CVPixelBufferRelease(dst);
            return NULL;
        }
        return dst;
    }
    return NULL;
}

- (void)ingestFrame:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return;
    [_lock lock];
    // Raw copy -> _raw (== CMSampleBufferCreateCopy into ivar 0x50).
    CVPixelBufferRetain(pixelBuffer);
    if (_raw) CVPixelBufferRelease(_raw);
    _raw = pixelBuffer;
    // CCW90 pre-rotated -> _rotated (== create90ImageBuffer: into ivar 0x70). Both stored
    // under the one lock, exactly like setYUVSampleBuffer:.
    if (_rotated) { CVPixelBufferRelease(_rotated); _rotated = NULL; }
    _rotated = [self create90Locked:pixelBuffer];
    _updatedAt = VCamNow();
    [_lock unlock];
}

- (BOOL)beginEmitAccessWithMaxAge:(NSTimeInterval)maxAgeSeconds {
    [_lock lock];
    if (_raw && (VCamNow() - _updatedAt) <= maxAgeSeconds) return YES;   // lock stays held
    [_lock unlock];
    return NO;
}

- (CVPixelBufferRef)rawFrameLocked { return _raw; }
- (CVPixelBufferRef)rotatedFrameLocked { return _rotated; }
- (void)endEmitAccess { [_lock unlock]; }

- (void)clear {
    [_lock lock];
    if (_raw) { CVPixelBufferRelease(_raw); _raw = NULL; }
    if (_rotated) { CVPixelBufferRelease(_rotated); _rotated = NULL; }
    _updatedAt = 0;
    [_lock unlock];
}

@end

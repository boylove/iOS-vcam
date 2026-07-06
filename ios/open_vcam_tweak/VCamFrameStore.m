#import "VCamFrameStore.h"
#import <time.h>

@implementation VCamFrameStore {
    CVPixelBufferRef _latest;      // retained
    NSTimeInterval _updatedAt;     // CACurrentMediaTime-equivalent
    NSLock *_lock;
}

+ (instancetype)shared {
    static VCamFrameStore *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamFrameStore alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _latest = NULL;
        _updatedAt = 0;
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (void)dealloc {
    if (_latest) {
        CVPixelBufferRelease(_latest);
        _latest = NULL;
    }
}

static NSTimeInterval VCamNow(void) {
    // Monotonic seconds; avoids wall-clock jumps.
    return (NSTimeInterval)clock_gettime_nsec_np(CLOCK_MONOTONIC) / (NSTimeInterval)NSEC_PER_SEC;
}

- (void)setLatestFrame:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return;
    CVPixelBufferRetain(pixelBuffer);
    [_lock lock];
    CVPixelBufferRef old = _latest;
    _latest = pixelBuffer;
    _updatedAt = VCamNow();
    [_lock unlock];
    if (old) CVPixelBufferRelease(old);
}

- (CVPixelBufferRef)copyFreshFrameWithMaxAge:(NSTimeInterval)maxAgeSeconds {
    CVPixelBufferRef result = NULL;
    [_lock lock];
    if (_latest && (VCamNow() - _updatedAt) <= maxAgeSeconds) {
        result = _latest;
        CVPixelBufferRetain(result);
    }
    [_lock unlock];
    return result;
}

- (void)clear {
    [_lock lock];
    CVPixelBufferRef old = _latest;
    _latest = NULL;
    _updatedAt = 0;
    [_lock unlock];
    if (old) CVPixelBufferRelease(old);
}

@end

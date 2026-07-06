#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Thread-safe holder for the most recently decoded camera-replacement frame.
///
/// The RTMP/decoder pipeline pushes CVPixelBuffers in; the capture-delegate
/// hook pops the latest one out. A watchdog (staleness threshold) makes the
/// hook fail-open to the real camera when decoding stalls, so a dead stream
/// never produces a frozen or black preview.
@interface VCamFrameStore : NSObject

+ (instancetype)shared;

/// Store a freshly decoded frame (retains it, releasing any previous frame).
- (void)setLatestFrame:(CVPixelBufferRef)pixelBuffer;

/// Return a retained copy of the latest frame if it is newer than
/// `maxAgeSeconds`, otherwise NULL. Caller must CFRelease a non-NULL result.
- (nullable CVPixelBufferRef)copyFreshFrameWithMaxAge:(NSTimeInterval)maxAgeSeconds CF_RETURNS_RETAINED;

/// Drop the stored frame (e.g. on RTMP disconnect).
- (void)clear;

@end

NS_ASSUME_NONNULL_END

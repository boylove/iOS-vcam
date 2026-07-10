#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Engine frame store — faithful to the closed vcamera's engine object. It holds the raw
/// decoded frame (== engine ivar 0x50) AND a CCW90 pre-rotated copy (== ivar 0x70), both
/// produced under ONE recursive lock (== ivar 0x18).
///
/// - The decode thread calls `-ingestFrame:` — under the lock it stores the raw frame and
///   pre-rotates a CCW90 copy (faithful to `setYUVSampleBuffer:` 0x82ddc ->
///   `create90ImageBuffer:` 0x829e0).
/// - The capture-hook thread wraps its pick + VTPixelTransfer in
///   `-beginEmitAccessWithMaxAge:` / `-endEmitAccess`, so the transfer runs in the SAME
///   critical section as the ingest rotation (faithful to `modifyImageBuffer:` 0x84458,
///   which also holds ivar 0x18). That single shared lock is what serialises the rotation
///   and the transfer so they never overlap on the GPU — splitting it into two locks is
///   exactly what caused the 0.5.7 IOSurface-fence cross-deadlock.
@interface VCamFrameStore : NSObject

+ (instancetype)shared;

/// Decode-thread ingest: store the raw frame and, under the engine lock, pre-rotate a CCW90
/// copy. Faithful to `setYUVSampleBuffer:`.
- (void)ingestFrame:(CVPixelBufferRef)pixelBuffer;

/// Capture-thread emit: acquire the engine lock and confirm a fresh frame exists (younger
/// than `maxAgeSeconds`). Returns NO with the lock NOT held when none. On YES the caller
/// reads `-rawFrameLocked` / `-rotatedFrameLocked`, does its single transfer, then MUST call
/// `-endEmitAccess`. The buffers are valid only between begin/end.
- (BOOL)beginEmitAccessWithMaxAge:(NSTimeInterval)maxAgeSeconds;
- (nullable CVPixelBufferRef)rawFrameLocked;
- (nullable CVPixelBufferRef)rotatedFrameLocked;
- (void)endEmitAccess;

/// Drop the stored frames (e.g. on RTMP disconnect).
- (void)clear;

@end

NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>

NS_ASSUME_NONNULL_BEGIN

/// Engine frame store — faithful to the closed vcamera's engine object. It holds the raw
/// decoded frame (== engine ivar 0x50) AND a CCW90 pre-rotated copy (== ivar 0x70), both
/// produced under ONE recursive lock (== ivar 0x18).
///
/// - The decode thread calls `-ingestSampleBuffer:` — under the lock it stores the raw frame and
///   pre-rotates a CCW90 copy (faithful to `setYUVSampleBuffer:` 0x82ddc ->
///   `create90ImageBuffer:` 0x829e0).
/// - The capture-hook thread wraps its pick + VTPixelTransfer in
///   `-beginEmitAccess` / `-endEmitAccess`, so the transfer runs in the SAME
///   critical section as the ingest rotation (faithful to `modifyImageBuffer:` 0x84458,
///   which also holds ivar 0x18). That single shared lock is what serialises the rotation
///   and the transfer so they never overlap on the GPU — splitting it into two locks is
///   exactly what caused the 0.5.7 IOSurface-fence cross-deadlock.
@interface VCamFrameStore : NSObject

+ (instancetype)shared;

/// Decode-thread ingest: store the raw decoded frame (as a CMSampleBuffer, == ivar 0x50)
/// and, under the engine lock, pre-rotate a CCW90 copy of its image buffer (== ivar 0x70).
/// Faithful to `setYUVSampleBuffer:` (0x82ddc) — the decoder wraps its CVPixelBuffer into a
/// CMSampleBuffer (with a synthetic monotonic timestamp) BEFORE handing it here, exactly
/// like the original's Helper -imageBufferToSampleBuffer:timeStamp: -> -outputFrame: chain.
- (void)ingestSampleBuffer:(CMSampleBufferRef)sampleBuffer;

/// Capture-thread emit: acquire the engine lock and confirm a frame exists. Returns NO with
/// the lock NOT held when there is none. On YES the caller reads `-rawFrameLocked` /
/// `-rotatedFrameLocked`, does its single transfer, then MUST call `-endEmitAccess`. The
/// buffers are valid only between begin/end. NO staleness/age check — faithful to
/// modifyImageBuffer: (0x84458) which gates ONLY on _bLive + ivar 0x50 != NULL (a stalled
/// stream keeps overwriting with the last OBS frame; a disconnect clears it via -clear).
- (BOOL)beginEmitAccess;
- (nullable CVPixelBufferRef)rawFrameLocked;
- (nullable CVPixelBufferRef)rotatedFrameLocked;
- (void)endEmitAccess;

/// The scale/pixel-format transfer session (== engine ivar 0x88), created + configured at init
/// (Trim + GPU-accel + 709/601), NOT lazily. The emit does its single VTPixelTransferSessionTransferImage
/// with this. NULL only if the session failed to create.
- (nullable VTPixelTransferSessionRef)transferSession;

/// STILL-ONLY transfer session — identical to -transferSession except its destination color
/// primaries are Display P3 (not 709), so the OBS frame is gamut-mapped 709->P3 to match the P3
/// tag deferredmediad stamps on the saved HEIC (fixes the saved-photo red cast; preview/record
/// keep the 709 -transferSession). Created eagerly at init; NULL -> caller falls back to
/// -transferSession (fail-open). Used only for the full-res still (Tweak.xm isStill gate).
- (nullable VTPixelTransferSessionRef)stillTransferSession;

/// Set the engine "live" flag (== _bLive / -setLive:, ivar 9). The emit overwrites ONLY when
/// live AND a frame exists. The RTMP layer sets YES on connect and NO on disconnect WITHOUT
/// clearing the frame — so a disconnected stream falls open to the real camera via this gate
/// (not by dropping the frame), and a reconnect resumes from the kept last frame, exactly like
/// the closed vcamera (whose clearCache never touches the camera frame 0x50/0x70; setLive: is
/// driven from the RTMP accept callback).
- (void)setLive:(BOOL)live;

/// Drop the stored frames (e.g. on full stop). Does NOT change the live flag.
- (void)clear;

@end

NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns the RTMP pull thread. Pulls the configured stream, parses FLV/AVC
/// video tags, and drives VCamH264Decoder, which pushes frames into
/// VCamFrameStore. Audio tags are currently ignored (video-first).
///
/// Start it once; it self-manages reconnects and honours the live enable
/// state from VCamConfig. Idempotent.
@interface VCamRTMPSource : NSObject

+ (instancetype)shared;

/// Audio-only mode: skip H264 video decode and the frame store entirely, only demux + decode the
/// AAC audio track. Set BEFORE ensureStarted. Used in an app process (TikTok) where OpenVCam only
/// replaces the microphone (video is overwritten by the mediaserverd instance). Default NO.
@property (nonatomic, assign) BOOL audioOnly;

/// Ensure the pull thread is running (no-op if already started).
- (void)ensureStarted;

/// Request the pull thread to stop and clear the frame store.
- (void)stop;

@end

NS_ASSUME_NONNULL_END

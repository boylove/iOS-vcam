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

/// Ensure the pull thread is running (no-op if already started).
- (void)ensureStarted;

/// Request the pull thread to stop and clear the frame store.
- (void)stop;

@end

NS_ASSUME_NONNULL_END

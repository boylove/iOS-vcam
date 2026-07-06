#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps a VideoToolbox H264 decode session. Fed AVCC (length-prefixed) NAL
/// units parsed out of the RTMP/FLV stream; decoded NV12 CVPixelBuffers are
/// pushed into VCamFrameStore. All methods are safe to call from the RTMP
/// reader thread; decode is synchronous per frame.
@interface VCamH264Decoder : NSObject

/// (Re)configure the session from an FLV AVCDecoderConfigurationRecord.
/// Extracts SPS/PPS and the NAL-unit length size. Returns NO on parse failure.
- (BOOL)configureWithAVCDecoderConfigurationRecord:(NSData *)record;

/// Decode one access unit. `avccData` is one or more NAL units, each prefixed
/// by a big-endian length of `naluLengthSize` bytes (as delivered by FLV).
/// No-op (returns NO) until configured.
- (BOOL)decodeAccessUnit:(NSData *)avccData
     compositionTimeMs:(int32_t)compositionTimeMs
                 dtsMs:(int64_t)dtsMs;

/// Tear down the session (e.g. on stream reconfigure or disconnect).
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END

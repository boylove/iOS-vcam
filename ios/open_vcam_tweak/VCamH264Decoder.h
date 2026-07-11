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

/// Decode one access unit. `data`/`len` is one or more NAL units, each prefixed
/// by a big-endian length of `naluLengthSize` bytes (as delivered by FLV).
/// No-op (returns NO) until configured.
///
/// ZERO-COPY, faithful to the original's `-decode:size:` (0x87390), whose input is a
/// raw `(void *, int)` wrapped no-copy (kCFAllocatorNull) straight from librtmp's reassembled
/// `m_body` — no intermediate NSData. `data` MUST stay valid until this returns; it does,
/// because the RTMP reader thread calls this synchronously and the VT decode below is
/// synchronous (flags=0), so the block buffer is fully consumed before `data` is reused.
- (BOOL)decodeAccessUnit:(const void *)data
                  length:(size_t)len
     compositionTimeMs:(int32_t)compositionTimeMs
                 dtsMs:(int64_t)dtsMs;

/// Tear down the session (e.g. on stream reconfigure or disconnect).
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END

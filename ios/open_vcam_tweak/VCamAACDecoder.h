#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Decodes the AAC audio track of the OBS RTMP/FLV stream to interleaved int16 PCM and pushes it
/// straight into the mediaserverd mic-replacement ring (VCamAudioSink / VCamAudioMS.x). This is
/// the audio analogue of VCamH264Decoder: it is fed the raw AAC access units parsed out of the
/// FLV audio tags, decodes them via an AudioConverter configured from the stream's
/// AudioSpecificConfig, and forwards the PCM. All methods run on the single RTMP reader thread.
@interface VCamAACDecoder : NSObject

/// (Re)configure the decoder from the FLV AAC sequence header's AudioSpecificConfig (the 2+ raw
/// ASC bytes, i.e. the audio tag body after the AACPacketType byte). Parses sample rate + channel
/// count and builds the AAC→int16 converter. Returns NO on parse/setup failure.
- (BOOL)configureWithAudioSpecificConfig:(NSData *)asc;

/// Decode one raw AAC access unit (`data`/`len`) to int16 PCM and push it into the ring. No-op
/// (returns NO) until configured. `data` need only remain valid for the duration of the call.
- (BOOL)decodeFrame:(const void *)data length:(size_t)len;

/// Tear down the converter (e.g. on stream reconfigure or disconnect).
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END

#import "VCamAACDecoder.h"
#import "VCamAudioSink.h"
#import "VCamLog.h"

#import <AudioToolbox/AudioToolbox.h>

// AAC-LC decodes 1024 PCM frames per access unit; HE-AAC/SBR up to 2048. Size the output
// scratch generously so one FillComplexBuffer call always fits.
static const UInt32 kVCamAACMaxOutFrames = 4096;

// ISO/IEC 14496-3 sampling-frequency index table (indices 0..12; 13..14 reserved, 15 = explicit).
static const uint32_t kVCamAACSampleRates[16] = {
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
    16000, 12000, 11025,  8000,  7350,     0,     0,     0,
};

// Per-decode input for the AudioConverter pull callback: hands over exactly one AAC packet.
typedef struct {
    const void *data;
    UInt32 len;
    UInt32 consumed;
    AudioStreamPacketDescription pd;
} VCamAACInput;

@implementation VCamAACDecoder {
    AudioConverterRef _conv;
    uint32_t _rate;
    uint32_t _channels;
    int16_t *_outBuf;         // interleaved int16 scratch (kVCamAACMaxOutFrames * _channels)
}

- (void)dealloc {
    [self invalidate];
}

- (void)invalidate {
    if (_conv) { AudioConverterDispose(_conv); _conv = NULL; }
    if (_outBuf) { free(_outBuf); _outBuf = NULL; }
    _rate = 0;
    _channels = 0;
}

- (BOOL)configureWithAudioSpecificConfig:(NSData *)asc {
    if (asc.length < 2) return NO;
    const uint8_t *b = (const uint8_t *)asc.bytes;

    // ASC: 5 bits audioObjectType, 4 bits samplingFrequencyIndex, 4 bits channelConfiguration.
    uint32_t freqIdx = ((b[0] & 0x07) << 1) | (b[1] >> 7);
    uint32_t chanConfig = (b[1] >> 3) & 0x0F;
    uint32_t rate = (freqIdx < 15) ? kVCamAACSampleRates[freqIdx] : 0;
    uint32_t channels = chanConfig;
    if (channels < 1 || channels > 2) channels = 2;   // ring path supports mono/stereo; OBS = stereo
    if (rate == 0 || rate > 192000) {
        VCamLog(@"aac: bad ASC (freqIdx=%u chan=%u) — cannot configure", freqIdx, chanConfig);
        return NO;
    }

    [self invalidate];   // rebuild cleanly on reconfigure

    AudioStreamBasicDescription in = {0};
    in.mFormatID = kAudioFormatMPEG4AAC;
    in.mSampleRate = rate;
    in.mChannelsPerFrame = channels;
    in.mFramesPerPacket = 1024;   // AAC-LC access unit

    AudioStreamBasicDescription out = {0};
    out.mFormatID = kAudioFormatLinearPCM;
    out.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    out.mSampleRate = rate;
    out.mChannelsPerFrame = channels;
    out.mBitsPerChannel = 16;
    out.mFramesPerPacket = 1;
    out.mBytesPerFrame = 2 * channels;
    out.mBytesPerPacket = 2 * channels;

    OSStatus st = AudioConverterNew(&in, &out, &_conv);
    if (st != noErr || !_conv) {
        VCamLog(@"aac: AudioConverterNew failed (%d)", (int)st);
        _conv = NULL;
        return NO;
    }

    // Raw AAC (not ADTS): the AudioSpecificConfig IS the decompression magic cookie.
    st = AudioConverterSetProperty(_conv, kAudioConverterDecompressionMagicCookie,
                                   (UInt32)asc.length, asc.bytes);
    if (st != noErr) {
        VCamLog(@"aac: set magic cookie failed (%d)", (int)st);
        AudioConverterDispose(_conv); _conv = NULL;
        return NO;
    }

    _outBuf = (int16_t *)malloc((size_t)kVCamAACMaxOutFrames * channels * sizeof(int16_t));
    if (!_outBuf) { AudioConverterDispose(_conv); _conv = NULL; return NO; }

    _rate = rate;
    _channels = channels;
    VCamLog(@"aac: configured rate=%u channels=%u", rate, channels);
    return YES;
}

static OSStatus VCamAACInputProc(AudioConverterRef conv, UInt32 *ioNumberDataPackets,
                                 AudioBufferList *ioData,
                                 AudioStreamPacketDescription **outDataPacketDescription,
                                 void *inUserData) {
    (void)conv;
    VCamAACInput *in = (VCamAACInput *)inUserData;
    if (in->consumed || in->len == 0) {   // one packet per decode; then signal "no more"
        *ioNumberDataPackets = 0;
        return noErr;
    }
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mData = (void *)in->data;
    ioData->mBuffers[0].mDataByteSize = in->len;
    ioData->mBuffers[0].mNumberChannels = 0;
    if (outDataPacketDescription) {
        in->pd.mStartOffset = 0;
        in->pd.mVariableFramesInPacket = 0;
        in->pd.mDataByteSize = in->len;
        *outDataPacketDescription = &in->pd;
    }
    *ioNumberDataPackets = 1;
    in->consumed = 1;
    return noErr;
}

- (BOOL)decodeFrame:(const void *)data length:(size_t)len {
    if (!_conv || !_outBuf || !data || len == 0) return NO;

    VCamAACInput input = { .data = data, .len = (UInt32)len, .consumed = 0 };

    AudioBufferList abl;
    abl.mNumberBuffers = 1;
    abl.mBuffers[0].mNumberChannels = _channels;
    abl.mBuffers[0].mDataByteSize = kVCamAACMaxOutFrames * _channels * (UInt32)sizeof(int16_t);
    abl.mBuffers[0].mData = _outBuf;

    UInt32 outPackets = kVCamAACMaxOutFrames;   // LPCM: 1 frame per packet
    OSStatus st = AudioConverterFillComplexBuffer(_conv, VCamAACInputProc, &input,
                                                  &outPackets, &abl, NULL);
    // The input proc supplies a single packet then returns 0, so a benign "ran out of input"
    // status alongside produced frames is expected — push whatever was decoded.
    if (outPackets == 0) {
        if (st != noErr) VCamLog(@"aac: decode produced 0 frames (%d)", (int)st);
        return NO;
    }
    IVCAMMediaActivePushPCM(_outBuf, outPackets, _rate, _channels);
    return YES;
}

@end

#import "VCamH264Decoder.h"
#import "VCamFrameStore.h"
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>

#import "VCamLog.h"

@implementation VCamH264Decoder {
    CMVideoFormatDescriptionRef _formatDesc;
    VTDecompressionSessionRef _session;
    int _naluLengthSize;
    NSData *_sps;
    NSData *_pps;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _formatDesc = NULL;
        _session = NULL;
        _naluLengthSize = 4;
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (void)invalidate {
    if (_session) {
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    if (_formatDesc) {
        CFRelease(_formatDesc);
        _formatDesc = NULL;
    }
}

#pragma mark - Configuration

- (BOOL)configureWithAVCDecoderConfigurationRecord:(NSData *)record {
    // AVCDecoderConfigurationRecord layout (ISO 14496-15):
    //  [0] version, [1] profile, [2] compat, [3] level,
    //  [4] 6 bits reserved + 2 bits lengthSizeMinusOne
    //  [5] 3 bits reserved + 5 bits numOfSPS, then SPS entries (2-byte len + data),
    //  then numOfPPS (1 byte) + PPS entries (2-byte len + data).
    const uint8_t *p = (const uint8_t *)record.bytes;
    NSUInteger len = record.length;
    if (len < 7) { VCamLog(@"decoder: config record too short (%lu)", (unsigned long)len); return NO; }

    int naluLengthSize = (p[4] & 0x03) + 1;
    NSUInteger idx = 5;

    int numSPS = p[idx] & 0x1F;
    idx += 1;
    NSData *sps = nil;
    for (int i = 0; i < numSPS && idx + 2 <= len; i++) {
        int spsLen = (p[idx] << 8) | p[idx + 1];
        idx += 2;
        if (idx + spsLen > len) { VCamLog(@"decoder: SPS overrun len=%lu idx=%lu spsLen=%d", (unsigned long)len, (unsigned long)idx, spsLen); return NO; }
        if (!sps) sps = [NSData dataWithBytes:(p + idx) length:spsLen];
        idx += spsLen;
    }

    if (idx >= len) { VCamLog(@"decoder: no room for PPS len=%lu idx=%lu numSPS=%d", (unsigned long)len, (unsigned long)idx, numSPS); return NO; }
    int numPPS = p[idx];
    idx += 1;
    NSData *pps = nil;
    for (int i = 0; i < numPPS && idx + 2 <= len; i++) {
        int ppsLen = (p[idx] << 8) | p[idx + 1];
        idx += 2;
        if (idx + ppsLen > len) { VCamLog(@"decoder: PPS overrun len=%lu idx=%lu ppsLen=%d", (unsigned long)len, (unsigned long)idx, ppsLen); return NO; }
        if (!pps) pps = [NSData dataWithBytes:(p + idx) length:ppsLen];
        idx += ppsLen;
    }

    if (!sps || !pps) {
        VCamLog(@"decoder: missing sps=%d pps=%d numSPS=%d numPPS=%d len=%lu b0=%02x b4=%02x",
                sps != nil, pps != nil, numSPS, (int)(idx < len ? p[5] : 0), (unsigned long)len, p[0], p[4]);
        return NO;
    }

    _sps = sps;
    _pps = pps;
    _naluLengthSize = naluLengthSize;
    return [self buildSession];
}

static void VCamDecodeOutput(void *decompressionOutputRefCon,
                             void *sourceFrameRefCon,
                             OSStatus status,
                             VTDecodeInfoFlags infoFlags,
                             CVImageBufferRef imageBuffer,
                             CMTime presentationTimeStamp,
                             CMTime presentationDuration) {
    (void)decompressionOutputRefCon;
    (void)sourceFrameRefCon;
    (void)infoFlags;
    (void)presentationTimeStamp;
    (void)presentationDuration;
    if (status != noErr || imageBuffer == NULL) {
        VCamLog(@"decoder: output status=%d imageBuffer=%p", (int)status, imageBuffer);
        return;
    }
    static uint64_t produced = 0;
    produced++;
    if (produced == 1 || (produced % 120) == 0) {
        VCamLog(@"decoder: produced %llu frames (%zux%zu)", produced,
                CVPixelBufferGetWidth((CVPixelBufferRef)imageBuffer),
                CVPixelBufferGetHeight((CVPixelBufferRef)imageBuffer));
    }
    [[VCamFrameStore shared] setLatestFrame:(CVPixelBufferRef)imageBuffer];
}

- (BOOL)buildSession {
    [self invalidate];

    const uint8_t *spsPtr = (const uint8_t *)_sps.bytes;
    const uint8_t *ppsPtr = (const uint8_t *)_pps.bytes;
    const uint8_t *paramSetPointers[2] = { spsPtr, ppsPtr };
    size_t paramSetSizes[2] = { (size_t)_sps.length, (size_t)_pps.length };

    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault, 2, paramSetPointers, paramSetSizes,
        _naluLengthSize, &_formatDesc);
    if (status != noErr || !_formatDesc) {
        VCamLog(@"decoder: format description failed (%d)", (int)status);
        _formatDesc = NULL;
        return NO;
    }

    VTDecompressionOutputCallbackRecord callback = {
        .decompressionOutputCallback = VCamDecodeOutput,
        .decompressionOutputRefCon = (__bridge void *)self,
    };

    // Forcing a destination format (NV12 + IOSurface) can make
    // VTDecompressionSessionCreate fail inside mediaserverd (observed err 1100).
    // Try with no destination attributes first (native output), then fall back;
    // CoreImage handles whatever pixel format the decoder yields.
    status = VTDecompressionSessionCreate(
        kCFAllocatorDefault, _formatDesc, NULL, NULL, &callback, &_session);
    if (status != noErr || !_session) {
        VCamLog(@"decoder: create failed (%d); retry with NV12", (int)status);
        _session = NULL;
        NSDictionary *destAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey:
                @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        };
        status = VTDecompressionSessionCreate(
            kCFAllocatorDefault, _formatDesc, NULL,
            (__bridge CFDictionaryRef)destAttrs, &callback, &_session);
        if (status != noErr || !_session) {
            VCamLog(@"decoder: session create failed (%d)", (int)status);
            _session = NULL;
            return NO;
        }
    }

    VCamLog(@"decoder: configured naluLen=%d sps=%lu pps=%lu",
            _naluLengthSize, (unsigned long)_sps.length, (unsigned long)_pps.length);
    return YES;
}

#pragma mark - Decode

- (BOOL)decodeAccessUnit:(NSData *)avccData
     compositionTimeMs:(int32_t)compositionTimeMs
                 dtsMs:(int64_t)dtsMs {
    if (!_session || !_formatDesc || avccData.length == 0) return NO;

    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, NULL, avccData.length, kCFAllocatorDefault,
        NULL, 0, avccData.length, 0, &blockBuffer);
    if (status != noErr || !blockBuffer) return NO;

    status = CMBlockBufferReplaceDataBytes(avccData.bytes, blockBuffer, 0, avccData.length);
    if (status != noErr) {
        CFRelease(blockBuffer);
        return NO;
    }

    CMSampleTimingInfo timing;
    timing.duration = kCMTimeInvalid;
    timing.presentationTimeStamp = CMTimeMake(dtsMs + compositionTimeMs, 1000);
    timing.decodeTimeStamp = CMTimeMake(dtsMs, 1000);

    size_t sampleSize = avccData.length;
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateReady(
        kCFAllocatorDefault, blockBuffer, _formatDesc, 1, 1, &timing,
        1, &sampleSize, &sampleBuffer);
    CFRelease(blockBuffer);
    if (status != noErr || !sampleBuffer) return NO;

    VTDecodeInfoFlags infoOut = 0;
    // Synchronous decode: callback fires before this returns — simpler/robust in mediaserverd.
    status = VTDecompressionSessionDecodeFrame(
        _session, sampleBuffer, 0, NULL, &infoOut);
    CFRelease(sampleBuffer);

    if (status != noErr) {
        VCamLog(@"decoder: decode failed (%d)", (int)status);
        return NO;
    }
    return YES;
}

@end

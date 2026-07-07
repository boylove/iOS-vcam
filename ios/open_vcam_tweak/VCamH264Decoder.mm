#import "VCamH264Decoder.h"
#import "VCamFrameStore.h"
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <time.h>

#import "VCamLog.h"

// Monotonic seconds, for backing off decoder-session rebuild attempts.
static double VCamMonoSeconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

@implementation VCamH264Decoder {
    CMVideoFormatDescriptionRef _formatDesc;
    VTDecompressionSessionRef _session;
    int _naluLengthSize;
    NSData *_sps;
    NSData *_pps;
    double _lastBuildFail;   // VCamMonoSeconds() of the last failed buildSession, or 0
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

    // Session reuse: many encoders re-send the AVC sequence header on every GOP.
    // If SPS/PPS and the NAL length size are unchanged and we already have a live
    // session, keep it — rebuilding each time is wasteful and repeatedly
    // creating/destroying VT sessions risks the decoder-pool exhaustion (err 1100)
    // documented in EXECUTION-PLAN §4.3.
    if (_session && _formatDesc && naluLengthSize == _naluLengthSize &&
        [sps isEqualToData:_sps] && [pps isEqualToData:_pps]) {
        return YES;
    }

    // Back off after a failed create: without a live session every GOP header
    // would otherwise call buildSession again (~every 1-2s), and hammering
    // VTDecompressionSessionCreate is exactly what wedges the decode-session pool.
    if (!_session && _lastBuildFail > 0 && (VCamMonoSeconds() - _lastBuildFail) < 2.0) {
        return NO;
    }

    _sps = sps;
    _pps = pps;
    _naluLengthSize = naluLengthSize;
    BOOL ok = [self buildSession];
    _lastBuildFail = ok ? 0 : VCamMonoSeconds();
    return ok;
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

    // Stamp the ITU-R colour/chroma metadata the original vcamera attaches to its
    // decoded buffers, so the downstream VTPixelTransferSession does the YCbCr
    // colour-range/matrix conversion correctly (a fresh buffer with no colour
    // info converts wrong / dark). kCVAttachmentMode_ShouldPropagate carries it
    // through to the transferred replacement buffer.
    CVBufferSetAttachment(imageBuffer, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(imageBuffer, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(imageBuffer, kCVImageBufferChromaLocationTopFieldKey,
                          kCVImageBufferChromaLocation_Left, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(imageBuffer, kCVImageBufferChromaLocationBottomFieldKey,
                          kCVImageBufferChromaLocation_Left, kCVAttachmentMode_ShouldPropagate);

    static uint64_t produced = 0;
    produced++;
    if (produced == 1)
        VCamLog(@"decoder: first frame decoded (%zux%zu)",
                CVPixelBufferGetWidth((CVPixelBufferRef)imageBuffer),
                CVPixelBufferGetHeight((CVPixelBufferRef)imageBuffer));
#if VCAM_DEBUG
    if ((produced % 120) == 0) {
        VCamDebugLog(@"decoder: produced %llu frames (%zux%zu)", produced,
                     CVPixelBufferGetWidth((CVPixelBufferRef)imageBuffer),
                     CVPixelBufferGetHeight((CVPixelBufferRef)imageBuffer));
    }
#endif
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

    // Match the closed vcamera's decoder setup, which does NOT hit the err 1100
    // our old forced-software / NULL-destination path did. Reverse-engineered from
    // vcamera.dylib initDecoder:...:
    //   * let VideoToolbox choose the decoder (default spec => hardware); do NOT
    //     force EnableHardwareAcceleratedVideoDecoder=NO (the forced-software path
    //     was what failed to create inside mediaserverd),
    //   * give it explicit destination attributes (native size, biplanar YCbCr,
    //     IOSurface-backed) so VT allocates cleanly,
    //   * then mark the session realtime with a bounded thread count.
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(_formatDesc);
    NSDictionary *dstAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey     : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferWidthKey               : @(dims.width),
        (id)kCVPixelBufferHeightKey              : @(dims.height),
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        // The original vcamera sets OpenGL compatibility here (its renderer is
        // GPUImage/OpenGL ES). We keep it for fidelity + so the decoded buffer is
        // GPU-friendly for the downstream VTPixelTransfer/Rotation sessions.
        (id)kCVPixelBufferOpenGLCompatibilityKey : @YES,
    };

    status = VTDecompressionSessionCreate(
        kCFAllocatorDefault, _formatDesc, NULL,
        (__bridge CFDictionaryRef)dstAttrs, &callback, &_session);
    if (status != noErr || !_session) {
        VCamLog(@"decoder: VTDecompressionSessionCreate failed (%d) %dx%d",
                (int)status, dims.width, dims.height);
        _session = NULL;
        // Leave no half-built state: drop the format description too, so we don't
        // sit with session==NULL but formatDesc!=NULL (which just silently drops
        // every NALU until the next rebuild). The next buildSession recreates it.
        if (_formatDesc) { CFRelease(_formatDesc); _formatDesc = NULL; }
        return NO;
    }

    // Realtime + bounded threads (matches the original; helps the session coexist
    // with the live camera pipeline in mediaserverd instead of contending it).
    VTSessionSetProperty(_session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_session, kVTDecompressionPropertyKey_ThreadCount,
                         (__bridge CFTypeRef)@2);

    VCamLog(@"decoder: configured naluLen=%d sps=%lu pps=%lu %dx%d",
            _naluLengthSize, (unsigned long)_sps.length, (unsigned long)_pps.length,
            dims.width, dims.height);
    return YES;
}

#pragma mark - Decode

- (BOOL)decodeAccessUnit:(NSData *)avccData
     compositionTimeMs:(int32_t)compositionTimeMs
                 dtsMs:(int64_t)dtsMs {
#if VCAM_DEBUG
    static uint64_t auCalls = 0;
    auCalls++;
    if (auCalls <= 3 || (auCalls % 120) == 0)
        VCamDebugLog(@"decoder: decodeAccessUnit #%llu len=%lu session=%p fmt=%p",
                     auCalls, (unsigned long)avccData.length, _session, _formatDesc);
#endif
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

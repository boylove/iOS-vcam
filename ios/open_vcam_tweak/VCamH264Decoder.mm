#import "VCamH264Decoder.h"
#import "VCamFrameStore.h"
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <time.h>

#import "VCamLog.h"

// Private: the synthetic monotonic output-timestamp counter lives on the INSTANCE (== the
// closed vcamera's Helper ivar 0x30), so it resets per decoder instance, not process-wide.
@interface VCamH264Decoder ()
- (double)nextOutputTimestamp;
@end

@implementation VCamH264Decoder {
    CMVideoFormatDescriptionRef _formatDesc;
    VTDecompressionSessionRef _session;
    int _naluLengthSize;
    NSData *_sps;
    NSData *_pps;
    double _outputTimestamp;   // synthetic output PTS counter, +20.0/frame (== Helper ivar 0x30)
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _formatDesc = NULL;
        _session = NULL;
        _naluLengthSize = 4;
        _outputTimestamp = 0.0;   // reset per instance, like the original's Helper ivar 0x30
    }
    return self;
}

// Returns the current synthetic output timestamp, then advances it +20.0 — faithful to the
// original Helper -outputFrame: (0x77d74: use ivar 0x30, then ivar 0x30 += 20.0).
- (double)nextOutputTimestamp {
    double t = _outputTimestamp;
    _outputTimestamp += 20.0;
    return t;
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

    // Always (re)build on each sequence header — faithful to the original. Its decoder-config
    // method (0x86f78, reached UNCONDITIONALLY from Helper -outputVideo:sps_size:pps:pps_size:
    // via objc_msgSend) releases the old session, frees the old SPS/PPS and creates a new
    // session EVERY time; there is NO "SPS/PPS unchanged -> reuse" and NO failure back-off. Those
    // were OpenVCam's own err-1100 workarounds; the err-1100 root cause (the old forced-software /
    // NULL-destination decoder setup) is already fixed by matching the original's config, so the
    // workarounds are removed too — exactly like the software-decoder fallback.
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
    // Wrap the decoded CVPixelBuffer into a CMSampleBuffer with a SYNTHETIC MONOTONIC
    // timestamp, EXACTLY like the closed vcamera's Helper -imageBufferToSampleBuffer:timeStamp:
    // (0x77c30) + -outputFrame: (0x77d24), then hand THAT to the engine (== setYUVSampleBuffer:).
    // The original does NOT use the RTMP DTS/CTS here: it drives its own counter that steps
    // +20.0 per frame, PTS = CMTimeMake((int64)(counter*600), 600) (timescale 600, flags valid),
    // duration/DTS invalid. It also CVPixelBufferLockBaseAddress's the buffer across the wrap —
    // which forces the GPU-decoded pixels to land (a sync point) — so we replicate that too.
    VCamH264Decoder *decoder = (__bridge VCamH264Decoder *)decompressionOutputRefCon;
    double outTs = decoder ? [decoder nextOutputTimestamp] : 0.0;   // per-instance counter (== ivar 0x30)
    CVPixelBufferLockBaseAddress((CVPixelBufferRef)imageBuffer, 0);
    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(NULL, imageBuffer, &fmt) == noErr && fmt) {
        CMSampleTimingInfo timing;
        timing.duration = kCMTimeInvalid;
        timing.presentationTimeStamp = CMTimeMake((int64_t)(outTs * 600.0), 600);
        timing.decodeTimeStamp = kCMTimeInvalid;
        CMSampleBufferRef sb = NULL;
        if (CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, imageBuffer, true, NULL, NULL,
                                               fmt, &timing, &sb) == noErr && sb) {
            [[VCamFrameStore shared] ingestSampleBuffer:sb];
            CFRelease(sb);
        }
        CFRelease(fmt);
    }
    CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)imageBuffer, 0);
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

    // Decoder setup, reverse-engineered from the closed vcamera (RE 0x86f78-0x872a8):
    //   * let VideoToolbox choose the decoder (default spec => hardware),
    //   * destination attributes = { 420f, width, height, OpenGLCompatibility } (below),
    //   * mark the session realtime with a bounded thread count (2).
    // (Dimensions: the original hand-parses the SPS; we use CMVideoFormatDescriptionGetDimensions,
    // which derives the same width/height from the same parameter sets.)
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(_formatDesc);
    NSDictionary *dstAttrs = @{
        // Decode to 420f = 420YpCbCr8BiPlanarFullRange, EXACTLY like the closed vcamera
        // whose decoder hardcodes this format (RE _orig_vcamera.dylib 0x86f3c-0x86f44:
        // mov #0x3066 / movk #0x3432 -> 0x34323066 '420f', stored to decoder ivar 0x2c,
        // then read into VTDecompressionSessionCreate's dstAttrs at 0x870b8). OpenVCam
        // previously used VideoRange (420v); FullRange matches the original's luma levels.
        (id)kCVPixelBufferPixelFormatTypeKey     : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (id)kCVPixelBufferWidthKey               : @(dims.width),
        (id)kCVPixelBufferHeightKey              : @(dims.height),
        // Faithful to the closed vcamera's decode dstAttrs (RE 0x870a0-0x87160): exactly
        // 4 keys — PixelFormatType, Width, Height, OpenGLCompatibility. NO explicit
        // IOSurfaceProperties (the original omits it and its overwrite works fine, because
        // OpenGLCompatibility:YES already implies IOSurface backing on iOS, and the source
        // buffer doesn't need to be IOSurface anyway — only the camera destination buffer
        // does, and that always is).
        (id)kCVPixelBufferOpenGLCompatibilityKey : @YES,
    };

    // Single create with NO fallback, faithful to the closed vcamera (RE 0x87238): one
    // VTDecompressionSessionCreate, videoDecoderSpecification left to default (the original
    // passes an ineffective/ignored dict there, functionally identical to NULL -> VT picks
    // hardware). The old forced-SOFTWARE fallback is removed: the err 1100 it guarded was
    // caused by OpenVCam's OWN earlier wrong setup (forced-SW / NULL dest attrs); now that
    // the setup matches the original, that failure mode is gone (the original ships no
    // fallback and works).
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

    // Wrap the AVCC data WITHOUT copying, faithful to the original (RE 0x873ec:
    // CMBlockBufferCreateWithMemoryBlock, blockAllocator = kCFAllocatorNull). Safe because the
    // decode below is SYNCHRONOUS (flags=0), so avccData outlives the whole decode call.
    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, (void *)avccData.bytes, avccData.length, kCFAllocatorNull,
        NULL, 0, avccData.length, 0, &blockBuffer);
    if (status != noErr || !blockBuffer) return NO;

    // NO sample timing — faithful to the closed vcamera's decode input (RE 0x87440):
    // CMSampleBufferCreateReady with numSampleTimingEntries=0 and sampleTimingArray=NULL. The
    // original does NOT feed the RTMP PTS/DTS to the decoder — it lets VideoToolbox order by
    // the bitstream, which avoids RTMP-timestamp-driven reordering (B-frames, mode-switch
    // residual frames, network jitter). The RTMP dtsMs/compositionTimeMs stay in the method
    // signature but are no longer used for decode timing, exactly like the original.
    (void)compositionTimeMs; (void)dtsMs;
    size_t sampleSize = avccData.length;
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateReady(
        kCFAllocatorDefault, blockBuffer, _formatDesc, 1, 0, NULL,
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

#import "VCamRTMPSource.h"
#import "VCamConfig.h"
#import "VCamH264Decoder.h"
#import "VCamAACDecoder.h"
#import "VCamAudioSink.h"
#import "VCamFrameStore.h"
#import "vcam_rtmp.h"

#import "VCamLog.h"

@interface VCamRTMPSource ()
@property (nonatomic, strong) VCamH264Decoder *decoder;
@property (nonatomic, strong) VCamAACDecoder *aacDecoder;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) volatile int stopFlag;    // hard stop -> thread exits
@property (nonatomic, assign) volatile int breakFlag;   // break THIS connection (stop OR url change)
@property (atomic, copy) NSString *connectedURL;        // the URL the live connection used
@end

@implementation VCamRTMPSource

+ (instancetype)shared {
    static VCamRTMPSource *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamRTMPSource alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _decoder = [[VCamH264Decoder alloc] init];
        _aacDecoder = [[VCamAACDecoder alloc] init];
        _started = NO;
        _stopFlag = 0;
    }
    return self;
}

#pragma mark - FLV/AVC parsing

// FLV video tag body handed up from the RTMP layer:
//   [0] (frameType<<4)|codecId ; codecId 7 = AVC
//   [1] AVCPacketType (0 = seq header, 1 = NALU, 2 = end)
//   [2..4] composition time (signed 24-bit, big-endian)
//   [5..] AVCDecoderConfigurationRecord (seq header) OR AVCC NAL units
- (void)handleVideoTag:(const uint8_t *)data length:(size_t)len timestampMs:(uint32_t)ts {
    if (len < 5) return;
    uint8_t codecId = data[0] & 0x0F;
    if (codecId != 7) return;                 // AVC/H264 only for now

    uint8_t pktType = data[1];
    int32_t cts = (int32_t)((data[2] << 16) | (data[3] << 8) | data[4]);
    if (cts & 0x800000) cts |= (int32_t)0xFF000000;  // sign-extend 24-bit

    const uint8_t *body = data + 5;
    size_t bodyLen = len - 5;

    if (pktType == 0) {
#if VCAM_DEBUG
        const uint8_t *b = body;
        VCamDebugLog(@"rtmp: seq header bodyLen=%zu bytes=%02x %02x %02x %02x %02x %02x",
                     bodyLen,
                     bodyLen>0?b[0]:0, bodyLen>1?b[1]:0, bodyLen>2?b[2]:0,
                     bodyLen>3?b[3]:0, bodyLen>4?b[4]:0, bodyLen>5?b[5]:0);
#endif
        NSData *record = [NSData dataWithBytes:body length:bodyLen];
        if (![self.decoder configureWithAVCDecoderConfigurationRecord:record]) {
            // Could be a genuine parse failure OR VTDecompressionSessionCreate
            // failing (e.g. 1100) — the decoder logs the specific cause; don't
            // mislabel every failure as a parse error.
            VCamLog(@"rtmp: decoder configure failed (see decoder log for cause)");
        }
    } else if (pktType == 1) {
#if VCAM_DEBUG
        static uint64_t naluTags = 0;
        naluTags++;
        if (naluTags <= 3 || (naluTags % 120) == 0)
            VCamDebugLog(@"rtmp: NALU tag #%llu bodyLen=%zu cts=%d", naluTags, bodyLen, cts);
#endif
        // Feed the NAL data straight to the decoder with NO intermediate NSData copy — faithful
        // to the original's zero-copy chain (librtmp reassembles the whole message into a
        // contiguous m_body, handed as a raw pointer to -decode:size:). `body` points into the
        // RTMP reader's buffer and is valid for the duration of this synchronous decode.
        [self.decoder decodeAccessUnit:body length:bodyLen compositionTimeMs:cts dtsMs:(int64_t)ts];
    }
}

// FLV audio tag body handed up from the RTMP layer:
//   [0] (soundFormat<<4)|(soundRate<<2)|(soundSize<<1)|soundType ; soundFormat 10 = AAC
//   [1] AACPacketType (0 = AudioSpecificConfig seq header, 1 = raw AAC frame)  [AAC only]
//   [2..] AudioSpecificConfig (seq header) OR one raw AAC access unit
- (void)handleAudioTag:(const uint8_t *)data length:(size_t)len timestampMs:(uint32_t)ts {
    if (len < 1) return;
    uint8_t soundFormat = (data[0] >> 4) & 0x0F;

    // Health/diagnostic (throttled): proves audio tags reach here and shows the AAC packet type
    // — decisively distinguishing "no audio delivered" from "seq header (type 0) never arrives".
    static uint64_t audTags = 0;
    audTags++;
    if (audTags <= 8 || (audTags % 500) == 0)
        VCamLog(@"rtmp: audio tag #%llu len=%zu fmt=%u aacType=%d", audTags, len, soundFormat,
                (soundFormat == 10 && len >= 2) ? (int)data[1] : -1);

    if (soundFormat != 10) return;            // AAC only
    if (len < 2) return;

    uint8_t aacPacketType = data[1];
    const uint8_t *body = data + 2;
    size_t bodyLen = len - 2;

    if (aacPacketType == 0) {                  // AudioSpecificConfig (sequence header)
        NSData *asc = [NSData dataWithBytes:body length:bodyLen];
        if (![self.aacDecoder configureWithAudioSpecificConfig:asc]) {
            VCamLog(@"rtmp: aac configure failed");
        }
    } else if (aacPacketType == 1) {           // raw AAC access unit
        [self.aacDecoder decodeFrame:body length:bodyLen ptsMs:(int64_t)ts];
    }
}

static void VCamRTMPMediaCallback(void *ctx, uint8_t msg_type,
                                  uint32_t timestamp_ms,
                                  const uint8_t *data, size_t len) {
    VCamRTMPSource *self = (__bridge VCamRTMPSource *)ctx;
    @autoreleasepool {
        if (msg_type == 9) {                   // video (AVC/H264)
            if (self.audioOnly) return;        // app process: mic-only, skip video decode
            [self handleVideoTag:data length:len timestampMs:timestamp_ms];
        } else if (msg_type == 8) {            // audio (AAC) -> mic replacement
            [self handleAudioTag:data length:len timestampMs:timestamp_ms];
        }
        // Hot URL switch: if the panel changed rtmpURL while this stream is live, break the
        // connection so the outer loop reconnects to the NEW url. The stop flag is polled at
        // every read boundary, so for a flowing stream this reconnects within a frame or two.
        if (self.stopFlag) {
            self.breakFlag = 1;
        } else {
            NSString *connected = self.connectedURL, *current = [VCamConfig shared].rtmpURL;
            if (connected && current && ![connected isEqualToString:current]) self.breakFlag = 1;
        }
    }
}

static void VCamRTMPLogCallback(void *ctx, const char *message) {
    (void)ctx;
    VCamLog(@"rtmp: %s", message);
}

#pragma mark - Lifecycle

- (void)ensureStarted {
    @synchronized (self) {
        if (self.started) return;
        self.started = YES;
        self.stopFlag = 0;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (!self.stopFlag) {
            @autoreleasepool {
                VCamConfig *cfg = [VCamConfig shared];
                if (!cfg.enabled) {
                    if (!self.audioOnly) {
                        [[VCamFrameStore shared] setLive:NO];
                        [[VCamFrameStore shared] clear];
                    }
                    IVCAMSetOBSStreaming(0);   // audio hook: fall open to the real mic
                    sleep(1);
                    continue;
                }

                NSString *url = cfg.rtmpURL;
                const char *curl = [url UTF8String];
                vcam_rtmp *client = vcam_rtmp_create(curl, VCamRTMPLogCallback, NULL);
                if (!client) {
                    VCamLog(@"rtmp: bad url %@", url);
                    sleep(2);
                    continue;
                }

                VCamLog(@"rtmp: connecting %@", url);
                // Break this connection on a hard stop OR a live URL change (see the media
                // callback). Arm the per-connection break flag and record the URL we're using.
                self.connectedURL = url;
                self.breakFlag = 0;
                // Live for the duration of the connection (== the original's setLive:YES from the
                // RTMP accept callback). The emit overwrites only while live && a frame exists.
                if (!self.audioOnly) [[VCamFrameStore shared] setLive:YES];
                vcam_rtmp_run(client, VCamRTMPMediaCallback,
                              (__bridge void *)self, &self->_breakFlag);
                vcam_rtmp_destroy(client);

                // Disconnected: drop the live gate but KEEP the last OBS frame — faithful to the
                // original, whose clearCache never clears the camera frame (0x50/0x70) and whose
                // disconnect only does setLive:NO. The gate (not a frame drop) falls open to the
                // real camera; a reconnect resumes from the kept frame. The decoder is kept too —
                // it rebuilds on the reconnect's sequence header (configure always rebuilds).
                if (!self.audioOnly) [[VCamFrameStore shared] setLive:NO];
                IVCAMSetOBSStreaming(0);   // OBS gone: audio hook falls open to the real mic

                if (!self.stopFlag) {
                    // Distinguish a real disconnect (back off 1s) from a hot URL change
                    // (reconnect immediately to the new stream).
                    if (![self.connectedURL isEqualToString:[VCamConfig shared].rtmpURL]) {
                        VCamLog(@"rtmp: url changed -> reconnecting to %@", [VCamConfig shared].rtmpURL);
                    } else {
                        VCamLog(@"rtmp: disconnected; retrying");
                        sleep(1);
                    }
                }
            }
        }

        @synchronized (self) {
            self.started = NO;
        }
    });
}

- (void)stop {
    self.stopFlag = 1;
    self.breakFlag = 1;   // also break the in-flight connection (the run polls breakFlag)
    [[VCamFrameStore shared] setLive:NO];
    [[VCamFrameStore shared] clear];   // full teardown: dropping the frame here is fine
}

@end

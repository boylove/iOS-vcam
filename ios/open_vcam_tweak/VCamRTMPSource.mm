#import "VCamRTMPSource.h"
#import "VCamConfig.h"
#import "VCamH264Decoder.h"
#import "VCamFrameStore.h"
#import "vcam_rtmp.h"

extern void VCamLog(NSString *format, ...);

@interface VCamRTMPSource ()
@property (nonatomic, strong) VCamH264Decoder *decoder;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) volatile int stopFlag;
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
        NSData *record = [NSData dataWithBytes:body length:bodyLen];
        if ([self.decoder configureWithAVCDecoderConfigurationRecord:record]) {
            VCamLog(@"rtmp: AVC sequence header applied");
        } else {
            VCamLog(@"rtmp: AVC sequence header parse failed");
        }
    } else if (pktType == 1) {
        NSData *avcc = [NSData dataWithBytes:body length:bodyLen];
        [self.decoder decodeAccessUnit:avcc compositionTimeMs:cts dtsMs:(int64_t)ts];
    }
}

static void VCamRTMPMediaCallback(void *ctx, uint8_t msg_type,
                                  uint32_t timestamp_ms,
                                  const uint8_t *data, size_t len) {
    if (msg_type != 9) return;                // video only (audio = phase 3)
    VCamRTMPSource *self = (__bridge VCamRTMPSource *)ctx;
    @autoreleasepool {
        [self handleVideoTag:data length:len timestampMs:timestamp_ms];
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
                    [[VCamFrameStore shared] clear];
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
                vcam_rtmp_run(client, VCamRTMPMediaCallback,
                              (__bridge void *)self, &self->_stopFlag);
                vcam_rtmp_destroy(client);

                [[VCamFrameStore shared] clear];
                [self.decoder invalidate];      // force fresh SPS/PPS on reconnect

                if (!self.stopFlag) {
                    VCamLog(@"rtmp: disconnected; retrying");
                    sleep(1);
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
    [[VCamFrameStore shared] clear];
}

@end

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <substrate.h>
#import <arpa/inet.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <stdarg.h>
#import <string.h>
#import <sys/socket.h>
#import <syslog.h>
#import <unistd.h>

#define IVCAM_MEDIA_ACTIVE_PREFS @"/var/mobile/Library/Preferences/com.iosvcam.audiobridge.media-active.plist"
#define IVCAM_MEDIA_ACTIVE_DISABLE_FLAG @"/var/mobile/Library/Preferences/com.iosvcam.audiobridge.media-active.disabled"
#define IVCAM_MEDIA_ACTIVE_PREFS_DOMAIN CFSTR("com.iosvcam.audiobridge.media-active")
#define IVCAM_MEDIA_ACTIVE_LOG @"iOSVCAMAudioBridgeMediaActive.log"
#define IVCAM_MEDIA_ACTIVE_MAGIC "IAF1"
#define IVCAM_MEDIA_ACTIVE_TARGET_BUNDLE @"com.apple.mediaserverd"
#define IVCAM_MEDIA_ACTIVE_TARGET_PROCESS @"mediaserverd"

#pragma pack(push, 1)
typedef struct {
    char magic[4];
    uint32_t sequence;
    uint64_t ptsUS;
    uint64_t durationUS;
    uint32_t payloadLength;
} IVCAMMediaActiveFrameHeader;
#pragma pack(pop)

static OSStatus (*gOriginalAudioUnitRender)(AudioUnit inUnit,
                                            AudioUnitRenderActionFlags *ioActionFlags,
                                            const AudioTimeStamp *inTimeStamp,
                                            UInt32 inOutputBusNumber,
                                            UInt32 inNumberFrames,
                                            AudioBufferList *ioData) = NULL;
static uint64_t gRenderCalls = 0;
static uint64_t gRenderReplaced = 0;
static uint64_t gRenderNoData = 0;
static uint64_t gRenderUnsupported = 0;
static uint64_t gRenderWrongBus = 0;

static NSArray<NSString *> *IVCAMMediaActiveLogPaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    [paths addObject:[@"/var/mobile/Library/Logs" stringByAppendingPathComponent:IVCAM_MEDIA_ACTIVE_LOG]];
    [paths addObject:[@"/var/tmp" stringByAppendingPathComponent:IVCAM_MEDIA_ACTIVE_LOG]];

    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length > 0) {
        [paths addObject:[tmp stringByAppendingPathComponent:IVCAM_MEDIA_ACTIVE_LOG]];
    }
    [paths addObject:[@"/tmp" stringByAppendingPathComponent:IVCAM_MEDIA_ACTIVE_LOG]];
    return paths;
}

static void IVCAMMediaActiveRotateIfNeeded(NSString *path) {
    NSDictionary<NSFileAttributeKey, id> *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSNumber *size = attrs[NSFileSize];
    if (size && [size unsignedLongLongValue] > 131072) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
}

static BOOL IVCAMMediaActiveAppendLog(NSString *path, NSData *data) {
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    IVCAMMediaActiveRotateIfNeeded(path);

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return [data writeToFile:path atomically:NO];
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return NO;

    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
        return YES;
    } @catch (NSException *exception) {
        @try { [handle closeFile]; } @catch (NSException *closeException) { }
        return NO;
    }
}

static void IVCAMMediaActiveLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *path in IVCAMMediaActiveLogPaths()) {
        if (IVCAMMediaActiveAppendLog(path, data)) break;
    }

    const char *utf8 = [message UTF8String];
    if (utf8) {
        syslog(LOG_NOTICE, "[iOSVCAMAudioBridgeMediaActive] %s", utf8);
    }
    NSLog(@"[iOSVCAMAudioBridgeMediaActive] %@", message);
}

static id IVCAMMediaActiveCopyPref(NSString *key) {
    CFPreferencesAppSynchronize(IVCAM_MEDIA_ACTIVE_PREFS_DOMAIN);
    CFTypeRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, IVCAM_MEDIA_ACTIVE_PREFS_DOMAIN);
    return CFBridgingRelease(value);
}

static BOOL IVCAMMediaActivePathExists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static BOOL IVCAMMediaActiveReadExact(int fd, void *buffer, size_t length) {
    uint8_t *cursor = (uint8_t *)buffer;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t n = recv(fd, cursor, remaining, 0);
        if (n <= 0) return NO;
        cursor += n;
        remaining -= (size_t)n;
    }
    return YES;
}

static BOOL IVCAMMediaActiveShouldLogCount(uint64_t count) {
    return count <= 5 || (count % 500) == 0;
}

static void IVCAMMediaActiveLogASBD(NSString *reason,
                                    UInt32 bus,
                                    UInt32 frames,
                                    const AudioStreamBasicDescription *asbd,
                                    const AudioBufferList *ioData) {
    if (!asbd) return;
    UInt32 buffers = ioData ? ioData->mNumberBuffers : 0;
    IVCAMMediaActiveLog(@"MEDIA_ACTIVE_ASBD_UNSUPPORTED reason=%@ bus=%u frames=%u rate=%.0f format=0x%08x flags=0x%08x channels=%u bits=%u bytesPerFrame=%u buffers=%u unsupported=%llu",
                        reason,
                        (unsigned int)bus,
                        (unsigned int)frames,
                        asbd->mSampleRate,
                        (unsigned int)asbd->mFormatID,
                        (unsigned int)asbd->mFormatFlags,
                        (unsigned int)asbd->mChannelsPerFrame,
                        (unsigned int)asbd->mBitsPerChannel,
                        (unsigned int)asbd->mBytesPerFrame,
                        (unsigned int)buffers,
                        gRenderUnsupported);
}

static void IVCAMMediaActiveLogStatsIfNeeded(void) {
    static uint64_t lastStatsAt = 0;
    if (gRenderCalls <= 5 || gRenderCalls - lastStatsAt >= 500) {
        lastStatsAt = gRenderCalls;
        IVCAMMediaActiveLog(@"MEDIA_ACTIVE_STATS render=%llu replaced=%llu noData=%llu unsupported=%llu wrongBus=%llu",
                            gRenderCalls,
                            gRenderReplaced,
                            gRenderNoData,
                            gRenderUnsupported,
                            gRenderWrongBus);
    }
}

@interface IVCAMMediaActiveAudioClient : NSObject
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) int port;
@property (nonatomic, assign) int sampleRate;
@property (nonatomic, assign) int channels;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, strong) NSMutableData *pcm;
@property (nonatomic, strong) NSLock *pcmLock;
+ (instancetype)sharedClient;
- (void)reloadPrefs;
- (void)ensureStarted;
- (NSData *)popPCMFrames:(NSUInteger)frames targetChannels:(int)targetChannels;
- (BOOL)fillAudioBufferList:(AudioBufferList *)ioData frames:(UInt32)frames bus:(UInt32)bus asbd:(const AudioStreamBasicDescription *)asbd;
@end

@implementation IVCAMMediaActiveAudioClient

+ (instancetype)sharedClient {
    static IVCAMMediaActiveAudioClient *client;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = [[IVCAMMediaActiveAudioClient alloc] init];
    });
    return client;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _enabled = NO;
        _host = @"127.10.10.10";
        _port = 1936;
        _sampleRate = 48000;
        _channels = 1;
        _started = NO;
        _pcm = [NSMutableData data];
        _pcmLock = [[NSLock alloc] init];
        [self reloadPrefs];
    }
    return self;
}

- (void)reloadPrefs {
    id disabledPref = IVCAMMediaActiveCopyPref(@"Disabled");
    if ([disabledPref respondsToSelector:@selector(boolValue)] && [disabledPref boolValue]) {
        self.enabled = NO;
        IVCAMMediaActiveLog(@"MEDIA_ACTIVE_PREFS disabled by CFPreferences flag");
        return;
    }

    if (IVCAMMediaActivePathExists(IVCAM_MEDIA_ACTIVE_DISABLE_FLAG)) {
        self.enabled = NO;
        IVCAMMediaActiveLog(@"MEDIA_ACTIVE_PREFS disabled by file flag");
        return;
    }

    NSDictionary *filePrefs = [NSDictionary dictionaryWithContentsOfFile:IVCAM_MEDIA_ACTIVE_PREFS];
    id enabledValue = IVCAMMediaActiveCopyPref(@"Enabled") ?: filePrefs[@"Enabled"];
    id hostValue = IVCAMMediaActiveCopyPref(@"Host") ?: filePrefs[@"Host"];
    id portValue = IVCAMMediaActiveCopyPref(@"Port") ?: filePrefs[@"Port"];
    id sampleRateValue = IVCAMMediaActiveCopyPref(@"SampleRate") ?: filePrefs[@"SampleRate"];
    id channelsValue = IVCAMMediaActiveCopyPref(@"Channels") ?: filePrefs[@"Channels"];

    BOOL hasEnabledValue = [enabledValue respondsToSelector:@selector(boolValue)];
    self.enabled = hasEnabledValue ? [enabledValue boolValue] : YES;
    if ([hostValue isKindOfClass:[NSString class]] && [hostValue length] > 0) self.host = hostValue;
    if ([portValue respondsToSelector:@selector(intValue)] && [portValue intValue] > 0) self.port = [portValue intValue];
    if ([sampleRateValue respondsToSelector:@selector(intValue)] && [sampleRateValue intValue] > 0) self.sampleRate = [sampleRateValue intValue];
    if ([channelsValue respondsToSelector:@selector(intValue)] && ([channelsValue intValue] == 1 || [channelsValue intValue] == 2)) self.channels = [channelsValue intValue];

    IVCAMMediaActiveLog(@"MEDIA_ACTIVE_PREFS enabled=%d host=%@ port=%d rate=%d channels=%d source=%@",
                        self.enabled,
                        self.host,
                        self.port,
                        self.sampleRate,
                        self.channels,
                        hasEnabledValue ? @"prefs" : @"default");
}

- (void)ensureStarted {
    if (!self.enabled || self.started) return;
    self.started = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        uint64_t connectAttempts = 0;
        while (self.enabled) {
            @autoreleasepool {
                int fd = socket(AF_INET, SOCK_STREAM, 0);
                if (fd < 0) {
                    connectAttempts++;
                    if (IVCAMMediaActiveShouldLogCount(connectAttempts)) {
                        IVCAMMediaActiveLog(@"MEDIA_ACTIVE_SOCKET_FAILED errno=%d", errno);
                    }
                    sleep(1);
                    continue;
                }

                struct sockaddr_in addr;
                memset(&addr, 0, sizeof(addr));
                addr.sin_family = AF_INET;
                addr.sin_port = htons((uint16_t)self.port);
                if (inet_pton(AF_INET, [self.host UTF8String], &addr.sin_addr) != 1) {
                    close(fd);
                    IVCAMMediaActiveLog(@"MEDIA_ACTIVE_BAD_HOST %@", self.host);
                    sleep(1);
                    continue;
                }

                if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
                    int err = errno;
                    close(fd);
                    connectAttempts++;
                    if (connectAttempts <= 5 || (connectAttempts % 15) == 0) {
                        IVCAMMediaActiveLog(@"MEDIA_ACTIVE_CONNECT_WAIT host=%@ port=%d attempts=%llu errno=%d error=%s",
                                            self.host,
                                            self.port,
                                            connectAttempts,
                                            err,
                                            strerror(err));
                    }
                    sleep(1);
                    continue;
                }

                connectAttempts = 0;
                IVCAMMediaActiveLog(@"MEDIA_ACTIVE_CONNECTED connected to %@:%d", self.host, self.port);

                NSMutableData *helloData = [NSMutableData data];
                char c = 0;
                NSUInteger helloBytes = 0;
                while (helloBytes < 1024 && recv(fd, &c, 1, 0) == 1) {
                    helloBytes++;
                    [helloData appendBytes:&c length:1];
                    if (c == '\n') break;
                }
                NSString *hello = [[NSString alloc] initWithData:helloData encoding:NSUTF8StringEncoding];
                if (hello.length > 0) {
                    IVCAMMediaActiveLog(@"MEDIA_ACTIVE_HELLO %@", [hello stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);
                }

                while (self.enabled) {
                    IVCAMMediaActiveFrameHeader header;
                    if (!IVCAMMediaActiveReadExact(fd, &header, sizeof(header))) break;
                    if (memcmp(header.magic, IVCAM_MEDIA_ACTIVE_MAGIC, 4) != 0) {
                        IVCAMMediaActiveLog(@"MEDIA_ACTIVE_BAD_FRAME_MAGIC sequence=%u", header.sequence);
                        break;
                    }
                    if (header.payloadLength == 0 || header.payloadLength > 65536) {
                        IVCAMMediaActiveLog(@"MEDIA_ACTIVE_BAD_FRAME_LEN sequence=%u len=%u", header.sequence, header.payloadLength);
                        break;
                    }

                    NSMutableData *payload = [NSMutableData dataWithLength:header.payloadLength];
                    if (!IVCAMMediaActiveReadExact(fd, payload.mutableBytes, header.payloadLength)) break;

                    [self.pcmLock lock];
                    [self.pcm appendData:payload];
                    NSUInteger maxBytes = (NSUInteger)self.sampleRate * (NSUInteger)MAX(self.channels, 1) * 2 * 2;
                    if (self.pcm.length > maxBytes) {
                        NSRange drop = NSMakeRange(0, self.pcm.length - maxBytes);
                        [self.pcm replaceBytesInRange:drop withBytes:NULL length:0];
                    }
                    [self.pcmLock unlock];
                }

                close(fd);
                IVCAMMediaActiveLog(@"MEDIA_ACTIVE_DISCONNECTED bridge disconnected; retrying");
                sleep(1);
            }
        }
    });
}

- (NSData *)popPCMFrames:(NSUInteger)frames targetChannels:(int)targetChannels {
    if (!self.enabled) return nil;
    if (!(targetChannels == 1 || targetChannels == 2)) return nil;
    if (!(self.channels == 1 || self.channels == 2)) return nil;

    NSUInteger sourceBytesPerFrame = (NSUInteger)self.channels * 2;
    NSUInteger neededSource = frames * sourceBytesPerFrame;

    [self.pcmLock lock];
    if (self.pcm.length < neededSource) {
        [self.pcmLock unlock];
        return nil;
    }
    NSData *source = [self.pcm subdataWithRange:NSMakeRange(0, neededSource)];
    [self.pcm replaceBytesInRange:NSMakeRange(0, neededSource) withBytes:NULL length:0];
    [self.pcmLock unlock];

    if (self.channels == targetChannels) return source;

    const int16_t *inSamples = (const int16_t *)source.bytes;
    NSMutableData *converted = [NSMutableData dataWithLength:frames * (NSUInteger)targetChannels * 2];
    int16_t *outSamples = (int16_t *)converted.mutableBytes;

    if (self.channels == 1 && targetChannels == 2) {
        for (NSUInteger i = 0; i < frames; i++) {
            int16_t s = inSamples[i];
            outSamples[i * 2] = s;
            outSamples[i * 2 + 1] = s;
        }
    } else if (self.channels == 2 && targetChannels == 1) {
        for (NSUInteger i = 0; i < frames; i++) {
            int32_t mixed = ((int32_t)inSamples[i * 2] + (int32_t)inSamples[i * 2 + 1]) / 2;
            outSamples[i] = (int16_t)mixed;
        }
    }

    return converted;
}

- (BOOL)fillAudioBufferList:(AudioBufferList *)ioData frames:(UInt32)frames bus:(UInt32)bus asbd:(const AudioStreamBasicDescription *)asbd {
    if (!self.enabled || !ioData || !asbd || frames == 0) return NO;
    if (asbd->mSampleRate != (Float64)self.sampleRate) {
        gRenderUnsupported++;
        if (IVCAMMediaActiveShouldLogCount(gRenderUnsupported)) IVCAMMediaActiveLogASBD(@"sample-rate-mismatch", bus, frames, asbd, ioData);
        return NO;
    }
    if (asbd->mFormatID != kAudioFormatLinearPCM) {
        gRenderUnsupported++;
        if (IVCAMMediaActiveShouldLogCount(gRenderUnsupported)) IVCAMMediaActiveLogASBD(@"not-linear-pcm", bus, frames, asbd, ioData);
        return NO;
    }

    BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL isSignedInt = (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    BOOL isNonInterleaved = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 targetChannels = asbd->mChannelsPerFrame;
    if (targetChannels == 0 && isNonInterleaved) targetChannels = ioData->mNumberBuffers;
    if (!(targetChannels == 1 || targetChannels == 2)) {
        gRenderUnsupported++;
        if (IVCAMMediaActiveShouldLogCount(gRenderUnsupported)) IVCAMMediaActiveLogASBD(@"unsupported-channels", bus, frames, asbd, ioData);
        return NO;
    }

    if (!((isFloat && asbd->mBitsPerChannel == 32) || (isSignedInt && asbd->mBitsPerChannel == 16))) {
        gRenderUnsupported++;
        if (IVCAMMediaActiveShouldLogCount(gRenderUnsupported)) IVCAMMediaActiveLogASBD(@"unsupported-sample-format", bus, frames, asbd, ioData);
        return NO;
    }

    NSData *payload = [self popPCMFrames:frames targetChannels:(int)targetChannels];
    if (!payload) return NO;

    const int16_t *samples = (const int16_t *)payload.bytes;

    if (isFloat) {
        if (isNonInterleaved) {
            if (ioData->mNumberBuffers < targetChannels) return NO;
            for (UInt32 ch = 0; ch < targetChannels; ch++) {
                if (!ioData->mBuffers[ch].mData) return NO;
                float *out = (float *)ioData->mBuffers[ch].mData;
                UInt32 writableFrames = MIN(frames, ioData->mBuffers[ch].mDataByteSize / sizeof(float));
                for (UInt32 i = 0; i < writableFrames; i++) {
                    out[i] = (float)samples[i * targetChannels + ch] / 32768.0f;
                }
                ioData->mBuffers[ch].mDataByteSize = writableFrames * sizeof(float);
            }
        } else {
            if (ioData->mNumberBuffers < 1 || !ioData->mBuffers[0].mData) return NO;
            float *out = (float *)ioData->mBuffers[0].mData;
            UInt32 writableSamples = MIN(frames * targetChannels, ioData->mBuffers[0].mDataByteSize / sizeof(float));
            for (UInt32 i = 0; i < writableSamples; i++) {
                out[i] = (float)samples[i] / 32768.0f;
            }
            ioData->mBuffers[0].mDataByteSize = writableSamples * sizeof(float);
        }
        return YES;
    }

    if (isSignedInt) {
        if (isNonInterleaved) {
            if (ioData->mNumberBuffers < targetChannels) return NO;
            for (UInt32 ch = 0; ch < targetChannels; ch++) {
                if (!ioData->mBuffers[ch].mData) return NO;
                int16_t *out = (int16_t *)ioData->mBuffers[ch].mData;
                UInt32 writableFrames = MIN(frames, ioData->mBuffers[ch].mDataByteSize / sizeof(int16_t));
                for (UInt32 i = 0; i < writableFrames; i++) {
                    out[i] = samples[i * targetChannels + ch];
                }
                ioData->mBuffers[ch].mDataByteSize = writableFrames * sizeof(int16_t);
            }
        } else {
            if (ioData->mNumberBuffers < 1 || !ioData->mBuffers[0].mData) return NO;
            NSUInteger bytes = MIN((NSUInteger)ioData->mBuffers[0].mDataByteSize, payload.length);
            memcpy(ioData->mBuffers[0].mData, payload.bytes, bytes);
            ioData->mBuffers[0].mDataByteSize = (UInt32)bytes;
        }
        return YES;
    }

    return NO;
}

@end

static OSStatus IVCAMMediaActiveAudioUnitRender(AudioUnit inUnit,
                                                AudioUnitRenderActionFlags *ioActionFlags,
                                                const AudioTimeStamp *inTimeStamp,
                                                UInt32 inOutputBusNumber,
                                                UInt32 inNumberFrames,
                                                AudioBufferList *ioData) {
    OSStatus status = gOriginalAudioUnitRender ? gOriginalAudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData) : noErr;
    if (status != noErr || !ioData) return status;

    gRenderCalls++;
    if (inOutputBusNumber != 1) {
        gRenderWrongBus++;
        if (IVCAMMediaActiveShouldLogCount(gRenderWrongBus)) {
            IVCAMMediaActiveLog(@"MEDIA_ACTIVE_SKIP_BUS bus=%u frames=%u wrongBus=%llu", (unsigned int)inOutputBusNumber, (unsigned int)inNumberFrames, gRenderWrongBus);
        }
        IVCAMMediaActiveLogStatsIfNeeded();
        return status;
    }

    IVCAMMediaActiveAudioClient *client = [IVCAMMediaActiveAudioClient sharedClient];
    if (!client.enabled) return status;

    AudioStreamBasicDescription asbd;
    UInt32 size = sizeof(asbd);
    memset(&asbd, 0, sizeof(asbd));
    OSStatus formatStatus = AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inOutputBusNumber, &asbd, &size);
    if (formatStatus != noErr) {
        size = sizeof(asbd);
        formatStatus = AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inOutputBusNumber, &asbd, &size);
    }

    if (formatStatus != noErr) {
        gRenderUnsupported++;
        if (IVCAMMediaActiveShouldLogCount(gRenderUnsupported)) {
            IVCAMMediaActiveLog(@"MEDIA_ACTIVE_FORMAT_UNAVAILABLE bus=%u frames=%u status=%d unsupported=%llu",
                                (unsigned int)inOutputBusNumber,
                                (unsigned int)inNumberFrames,
                                (int)formatStatus,
                                gRenderUnsupported);
        }
        IVCAMMediaActiveLogStatsIfNeeded();
        return status;
    }

    if (asbd.mFormatID == kAudioFormatLinearPCM && asbd.mSampleRate == (Float64)client.sampleRate) {
        [client ensureStarted];
    }

    BOOL replaced = [client fillAudioBufferList:ioData frames:inNumberFrames bus:inOutputBusNumber asbd:&asbd];
    if (replaced) {
        gRenderReplaced++;
        if (IVCAMMediaActiveShouldLogCount(gRenderReplaced)) {
            IVCAMMediaActiveLog(@"MEDIA_ACTIVE_REPLACED bus=%u frames=%u replaced=%llu",
                                (unsigned int)inOutputBusNumber,
                                (unsigned int)inNumberFrames,
                                gRenderReplaced);
        }
    } else {
        gRenderNoData++;
    }
    IVCAMMediaActiveLogStatsIfNeeded();

    return status;
}

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *processName = [[NSProcessInfo processInfo] processName] ?: @"";
        NSString *executablePath = [[NSProcessInfo processInfo] arguments].firstObject ?: @"";
        BOOL targetProcess = [bundleID isEqualToString:IVCAM_MEDIA_ACTIVE_TARGET_BUNDLE] || [processName isEqualToString:IVCAM_MEDIA_ACTIVE_TARGET_PROCESS];

        IVCAMMediaActiveLog(@"MEDIA_ACTIVE_LOADED bundle=%@ process=%@ executable=%@ uid=%d euid=%d target=%d",
                            bundleID,
                            processName,
                            executablePath,
                            getuid(),
                            geteuid(),
                            targetProcess);

        IVCAMMediaActiveLog(@"MEDIA_ACTIVE_PATHS tweakinject=%d autopatches=%d pkgmirror=%d disabled=%d",
                            IVCAMMediaActivePathExists(@"/usr/lib/TweakInject"),
                            IVCAMMediaActivePathExists(@"/usr/lib/DynamicPatches/AutoPatches.dylib"),
                            IVCAMMediaActivePathExists(@"/var/mobile/Library/pkgmirror/Library/MobileSubstrate/DynamicLibraries"),
                            IVCAMMediaActivePathExists(IVCAM_MEDIA_ACTIVE_DISABLE_FLAG));

        if (IVCAMMediaActivePathExists(IVCAM_MEDIA_ACTIVE_DISABLE_FLAG)) {
            IVCAMMediaActiveLog(@"MEDIA_ACTIVE_DISABLED by file flag");
            return;
        }

        if (!targetProcess) {
            IVCAMMediaActiveLog(@"MEDIA_ACTIVE_INACTIVE not media target");
            return;
        }

        IVCAMMediaActiveAudioClient *client = [IVCAMMediaActiveAudioClient sharedClient];
        [client reloadPrefs];
        [client ensureStarted];

        MSHookFunction((void *)AudioUnitRender, (void *)IVCAMMediaActiveAudioUnitRender, (void **)&gOriginalAudioUnitRender);
        IVCAMMediaActiveLog(@"MEDIA_ACTIVE_READY AudioUnitRender hook installed; startup client enabled for connection diagnostics");
    }
}

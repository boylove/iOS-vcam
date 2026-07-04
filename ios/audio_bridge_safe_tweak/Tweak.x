#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <unistd.h>
#import <stdarg.h>

#define IVCAM_SAFE_PREFS @"/var/mobile/Library/Preferences/com.iosvcam.audiobridge.safe.plist"
#define IVCAM_SAFE_DISABLE_FLAG @"/var/mobile/Library/Preferences/com.iosvcam.audiobridge.safe.disabled"
#define IVCAM_SAFE_PREFS_DOMAIN CFSTR("com.iosvcam.audiobridge.safe")
#define IVCAM_SAFE_LOG @"iOSVCAMAudioBridgeSafe.log"
#define IVCAM_SAFE_MAGIC "IAF1"
#define IVCAM_SAFE_TARGET_BUNDLE @"com.zhiliaoapp.musically"

#pragma pack(push, 1)
typedef struct {
    char magic[4];
    uint32_t sequence;
    uint64_t ptsUS;
    uint64_t durationUS;
    uint32_t payloadLength;
} IVCAMSafeFrameHeader;
#pragma pack(pop)

static NSMutableDictionary<NSString *, NSValue *> *gOriginalIMPs;
static NSMutableSet<NSString *> *gHookedDelegateClasses;
static NSLock *gHookLock;
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

static NSString *IVCAMSafeLogPath(void) {
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length > 0) {
        return [tmp stringByAppendingPathComponent:IVCAM_SAFE_LOG];
    }
    return [@"/tmp" stringByAppendingPathComponent:IVCAM_SAFE_LOG];
}

static id IVCAMSafeCopyPref(NSString *key) {
    CFPreferencesAppSynchronize(IVCAM_SAFE_PREFS_DOMAIN);
    CFTypeRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, IVCAM_SAFE_PREFS_DOMAIN);
    return CFBridgingRelease(value);
}

static void IVCAMSafeLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *logPath = IVCAMSafeLogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        [data writeToFile:logPath atomically:NO];
    } else {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        }
    }

    NSLog(@"[iOSVCAMAudioBridgeSafe] %@", message);
}

@interface IVCAMSafeAudioClient : NSObject
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
- (BOOL)fillAudioBufferList:(AudioBufferList *)ioData frames:(UInt32)frames asbd:(const AudioStreamBasicDescription *)asbd;
- (CMSampleBufferRef)newReplacementForSampleBuffer:(CMSampleBufferRef)sampleBuffer CF_RETURNS_RETAINED;
@end

@implementation IVCAMSafeAudioClient

+ (instancetype)sharedClient {
    static IVCAMSafeAudioClient *client;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = [[IVCAMSafeAudioClient alloc] init];
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
    id disabledPref = IVCAMSafeCopyPref(@"Disabled");
    if ([disabledPref respondsToSelector:@selector(boolValue)] && [disabledPref boolValue]) {
        self.enabled = NO;
        IVCAMSafeLog(@"prefs disabled by CFPreferences flag");
        return;
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:IVCAM_SAFE_DISABLE_FLAG]) {
        self.enabled = NO;
        IVCAMSafeLog(@"prefs disabled by file flag");
        return;
    }

    NSDictionary *filePrefs = [NSDictionary dictionaryWithContentsOfFile:IVCAM_SAFE_PREFS];
    id enabledValue = IVCAMSafeCopyPref(@"Enabled") ?: filePrefs[@"Enabled"];
    id hostValue = IVCAMSafeCopyPref(@"Host") ?: filePrefs[@"Host"];
    id portValue = IVCAMSafeCopyPref(@"Port") ?: filePrefs[@"Port"];
    id sampleRateValue = IVCAMSafeCopyPref(@"SampleRate") ?: filePrefs[@"SampleRate"];
    id channelsValue = IVCAMSafeCopyPref(@"Channels") ?: filePrefs[@"Channels"];

    BOOL hasEnabledValue = [enabledValue respondsToSelector:@selector(boolValue)];
    self.enabled = hasEnabledValue ? [enabledValue boolValue] : YES;
    if ([hostValue isKindOfClass:[NSString class]] && [hostValue length] > 0) self.host = hostValue;
    if ([portValue respondsToSelector:@selector(intValue)] && [portValue intValue] > 0) self.port = [portValue intValue];
    if ([sampleRateValue respondsToSelector:@selector(intValue)] && [sampleRateValue intValue] > 0) self.sampleRate = [sampleRateValue intValue];
    if ([channelsValue respondsToSelector:@selector(intValue)] && ([channelsValue intValue] == 1 || [channelsValue intValue] == 2)) self.channels = [channelsValue intValue];

    IVCAMSafeLog(@"prefs enabled=%d host=%@ port=%d rate=%d channels=%d source=%@", self.enabled, self.host, self.port, self.sampleRate, self.channels, hasEnabledValue ? @"prefs" : @"default");
}

static BOOL IVCAMSafeReadExact(int fd, void *buffer, size_t length) {
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

- (void)ensureStarted {
    if (!self.enabled || self.started) return;
    self.started = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (self.enabled) {
            @autoreleasepool {
                int fd = socket(AF_INET, SOCK_STREAM, 0);
                if (fd < 0) {
                    sleep(1);
                    continue;
                }

                struct sockaddr_in addr;
                memset(&addr, 0, sizeof(addr));
                addr.sin_family = AF_INET;
                addr.sin_port = htons((uint16_t)self.port);
                inet_pton(AF_INET, [self.host UTF8String], &addr.sin_addr);

                if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
                    close(fd);
                    sleep(1);
                    continue;
                }

                IVCAMSafeLog(@"connected to %@:%d", self.host, self.port);

                char c = 0;
                NSUInteger helloBytes = 0;
                while (helloBytes < 1024 && recv(fd, &c, 1, 0) == 1) {
                    helloBytes++;
                    if (c == '\n') break;
                }

                while (self.enabled) {
                    IVCAMSafeFrameHeader header;
                    if (!IVCAMSafeReadExact(fd, &header, sizeof(header))) break;
                    if (memcmp(header.magic, IVCAM_SAFE_MAGIC, 4) != 0) break;
                    if (header.payloadLength == 0 || header.payloadLength > 65536) break;

                    NSMutableData *payload = [NSMutableData dataWithLength:header.payloadLength];
                    if (!IVCAMSafeReadExact(fd, payload.mutableBytes, header.payloadLength)) break;

                    [self.pcmLock lock];
                    [self.pcm appendData:payload];
                    NSUInteger maxBytes = (NSUInteger)self.sampleRate * MAX(self.channels, 1) * 2 * 2;
                    if (self.pcm.length > maxBytes) {
                        NSRange drop = NSMakeRange(0, self.pcm.length - maxBytes);
                        [self.pcm replaceBytesInRange:drop withBytes:NULL length:0];
                    }
                    [self.pcmLock unlock];
                }

                close(fd);
                IVCAMSafeLog(@"bridge disconnected; retrying");
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

- (BOOL)fillAudioBufferList:(AudioBufferList *)ioData frames:(UInt32)frames asbd:(const AudioStreamBasicDescription *)asbd {
    if (!self.enabled || !ioData || !asbd || frames == 0) return NO;
    if (asbd->mSampleRate != (Float64)self.sampleRate) return NO;
    if (asbd->mFormatID != kAudioFormatLinearPCM) return NO;

    BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL isSignedInt = (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    BOOL isNonInterleaved = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 targetChannels = asbd->mChannelsPerFrame;
    if (targetChannels == 0 && isNonInterleaved) targetChannels = ioData->mNumberBuffers;
    if (!(targetChannels == 1 || targetChannels == 2)) return NO;

    if (!((isFloat && asbd->mBitsPerChannel == 32) || (isSignedInt && asbd->mBitsPerChannel == 16))) return NO;

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

- (CMSampleBufferRef)newReplacementForSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.enabled || !sampleBuffer) return nil;

    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!format) return nil;

    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format);
    if (!asbd) return nil;

    if (asbd->mSampleRate != (Float64)self.sampleRate) return nil;
    if (asbd->mFormatID != kAudioFormatLinearPCM) return nil;
    if ((asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) == 0) return nil;
    if ((asbd->mFormatFlags & kAudioFormatFlagIsPacked) == 0) return nil;
    if ((asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0) return nil;
    if (asbd->mBitsPerChannel != 16) return nil;
    if (!(asbd->mChannelsPerFrame == 1 || asbd->mChannelsPerFrame == 2)) return nil;

    CMItemCount sampleCount = CMSampleBufferGetNumSamples(sampleBuffer);
    if (sampleCount <= 0) return nil;

    NSData *payload = [self popPCMFrames:(NSUInteger)sampleCount targetChannels:(int)asbd->mChannelsPerFrame];
    if (!payload) return nil;

    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                         NULL,
                                                         payload.length,
                                                         kCFAllocatorDefault,
                                                         NULL,
                                                         0,
                                                         payload.length,
                                                         0,
                                                         &block);
    if (status != noErr || !block) return nil;

    status = CMBlockBufferReplaceDataBytes(payload.bytes, block, 0, payload.length);
    if (status != noErr) {
        CFRelease(block);
        return nil;
    }

    CMSampleTimingInfo timing;
    status = CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timing);
    if (status != noErr) {
        timing.duration = CMTimeMake(1, (int32_t)asbd->mSampleRate);
        timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        timing.decodeTimeStamp = kCMTimeInvalid;
    }

    CMSampleBufferRef replacement = NULL;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                       block,
                                       format,
                                       sampleCount,
                                       1,
                                       &timing,
                                       0,
                                       NULL,
                                       &replacement);
    CFRelease(block);

    if (status != noErr) return nil;
    return replacement;
}

@end

static OSStatus IVCAMSafeAudioUnitRender(AudioUnit inUnit,
                                         AudioUnitRenderActionFlags *ioActionFlags,
                                         const AudioTimeStamp *inTimeStamp,
                                         UInt32 inOutputBusNumber,
                                         UInt32 inNumberFrames,
                                         AudioBufferList *ioData) {
    OSStatus status = gOriginalAudioUnitRender ? gOriginalAudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData) : noErr;
    if (status != noErr || !ioData) return status;

    if (inOutputBusNumber != 1) return status;

    gRenderCalls++;
    IVCAMSafeAudioClient *client = [IVCAMSafeAudioClient sharedClient];
    if (!client.enabled) return status;
    [client ensureStarted];

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
        return status;
    }

    BOOL replaced = [client fillAudioBufferList:ioData frames:inNumberFrames asbd:&asbd];
    if (replaced) {
        gRenderReplaced++;
    } else {
        gRenderNoData++;
    }

    return status;
}

static IMP IVCAMSafeOriginalIMPForObject(id object) {
    NSString *className = NSStringFromClass(object_getClass(object));
    NSValue *value = gOriginalIMPs[className];
    return value ? [value pointerValue] : NULL;
}

static void IVCAMSafeDidOutput(id self, SEL _cmd, id output, CMSampleBufferRef sampleBuffer, id connection) {
    IMP original = IVCAMSafeOriginalIMPForObject(self);
    if (!original) return;

    IVCAMSafeAudioClient *client = [IVCAMSafeAudioClient sharedClient];
    CMSampleBufferRef replacement = [client newReplacementForSampleBuffer:sampleBuffer];
    CMSampleBufferRef toSend = replacement ?: sampleBuffer;

    if (replacement) IVCAMSafeLog(@"AVCaptureAudioDataOutput replaced sample buffer");
    ((void (*)(id, SEL, id, CMSampleBufferRef, id))original)(self, _cmd, output, toSend, connection);

    if (replacement) CFRelease(replacement);
}

static void IVCAMSafeHookDelegateIfNeeded(id delegate) {
    if (!delegate) return;
    IVCAMSafeAudioClient *client = [IVCAMSafeAudioClient sharedClient];
    [client reloadPrefs];
    if (!client.enabled) return;

    Class cls = object_getClass(delegate);
    if (!cls) return;

    SEL selector = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;

    NSString *className = NSStringFromClass(cls);
    [gHookLock lock];
    if (![gHookedDelegateClasses containsObject:className]) {
        IMP original = NULL;
        MSHookMessageEx(cls, selector, (IMP)IVCAMSafeDidOutput, &original);
        if (original) {
            gOriginalIMPs[className] = [NSValue valueWithPointer:original];
            [gHookedDelegateClasses addObject:className];
            IVCAMSafeLog(@"hooked delegate %@", className);
        }
    }
    [gHookLock unlock];

    [client ensureStarted];
}

%hook AVCaptureAudioDataOutput

- (void)setSampleBufferDelegate:(id)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    IVCAMSafeHookDelegateIfNeeded(sampleBufferDelegate);
    %orig(sampleBufferDelegate, sampleBufferCallbackQueue);
}

%end

%ctor {
    @autoreleasepool {
        gOriginalIMPs = [NSMutableDictionary dictionary];
        gHookedDelegateClasses = [NSMutableSet set];
        gHookLock = [[NSLock alloc] init];

        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *processName = [[NSProcessInfo processInfo] processName] ?: @"";
        BOOL targetApp = [bundleID isEqualToString:IVCAM_SAFE_TARGET_BUNDLE] || [processName isEqualToString:@"TikTok"];
        IVCAMSafeLog(@"loaded into bundle=%@ process=%@ target=%d", bundleID, processName, targetApp);
        if (!targetApp) {
            IVCAMSafeLog(@"bundle/process not target; inactive");
            return;
        }

        IVCAMSafeAudioClient *client = [IVCAMSafeAudioClient sharedClient];
        [client reloadPrefs];
        [client ensureStarted];

        MSHookFunction((void *)AudioUnitRender, (void *)IVCAMSafeAudioUnitRender, (void **)&gOriginalAudioUnitRender);
        IVCAMSafeLog(@"AudioUnitRender hook installed");
    }
}

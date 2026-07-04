// Clean-room experimental audio companion for iOS-VCAM.
//
// This tweak intentionally implements only the microphone side of the planned
// pipeline. It does not replace the existing vcamera video path and does not
// include DiCoy's daemon, IOSurface, or media-file AVAssetReader code.

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <arpa/inet.h>
#import <errno.h>
#import <math.h>
#import <netinet/in.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

#define IVCAM_AUDIO_MAGIC "IAF1"
#define IVCAM_PREFS_PATH @"/var/mobile/Library/Preferences/com.iosvcam.audiobridge.plist"

// Matches scripts/audio_bridge.py FRAME_HEADER = struct.Struct("<4sIQQI").
typedef struct __attribute__((packed)) {
    char magic[4];
    uint32_t sequence;
    uint64_t ptsUS;
    uint64_t durationUS;
    uint32_t payloadLength;
} IVCAMAudioFrameHeader;

static NSMutableSet *gHookedAudioDelegateClasses;
static NSMutableDictionary *gOriginalAudioDelegateIMPs;

static void IVCAMLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[iOSVCAMAudioBridge] %@", message);
}

@interface IVCAMAudioBridgeClient : NSObject
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, strong) NSMutableData *pcmBuffer;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) int port;
@property (nonatomic, assign) int sourceSampleRate;
@property (nonatomic, assign) int sourceChannels;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL verbose;
@property (nonatomic, assign) BOOL readerStarted;
@property (nonatomic, assign) NSUInteger maxBufferedBytes;
+ (instancetype)sharedClient;
- (void)ensureStarted;
- (NSData *)takePCMBytes:(NSUInteger)byteCount;
- (int)currentSourceSampleRate;
- (int)currentSourceChannels;
@end

@implementation IVCAMAudioBridgeClient

+ (instancetype)sharedClient {
    static IVCAMAudioBridgeClient *client = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = [[IVCAMAudioBridgeClient alloc] init];
    });
    return client;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _pcmBuffer = [[NSMutableData alloc] init];
        _host = @"127.10.10.10";
        _port = 1936;
        _sourceSampleRate = 48000;
        _sourceChannels = 1;
        _enabled = YES;
        _verbose = NO;
        _maxBufferedBytes = 48000 * 2 * 2; // 2 seconds, 16-bit stereo worst-case default.
        [self loadPreferences];
    }
    return self;
}

- (void)loadPreferences {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:IVCAM_PREFS_PATH];
    if (![prefs isKindOfClass:[NSDictionary class]]) {
        return;
    }

    id enabledValue = prefs[@"Enabled"];
    if ([enabledValue respondsToSelector:@selector(boolValue)]) {
        self.enabled = [enabledValue boolValue];
    }

    NSString *hostValue = prefs[@"Host"];
    if ([hostValue isKindOfClass:[NSString class]] && hostValue.length > 0) {
        self.host = hostValue;
    }

    id portValue = prefs[@"Port"];
    if ([portValue respondsToSelector:@selector(intValue)]) {
        int parsedPort = [portValue intValue];
        if (parsedPort > 0 && parsedPort <= 65535) {
            self.port = parsedPort;
        }
    }

    id verboseValue = prefs[@"VerboseLogging"];
    if ([verboseValue respondsToSelector:@selector(boolValue)]) {
        self.verbose = [verboseValue boolValue];
    }
}

- (void)ensureStarted {
    @synchronized (self) {
        if (self.readerStarted) {
            return;
        }
        self.readerStarted = YES;
        [NSThread detachNewThreadSelector:@selector(readerThreadMain) toTarget:self withObject:nil];
    }
}

- (int)currentSourceSampleRate {
    [self.lock lock];
    int value = self.sourceSampleRate;
    [self.lock unlock];
    return value;
}

- (int)currentSourceChannels {
    [self.lock lock];
    int value = self.sourceChannels;
    [self.lock unlock];
    return value;
}

- (NSData *)takePCMBytes:(NSUInteger)byteCount {
    if (byteCount == 0) {
        return [NSData data];
    }

    [self.lock lock];
    if (self.pcmBuffer.length < byteCount) {
        [self.lock unlock];
        return nil;
    }

    NSData *data = [self.pcmBuffer subdataWithRange:NSMakeRange(0, byteCount)];
    [self.pcmBuffer replaceBytesInRange:NSMakeRange(0, byteCount) withBytes:NULL length:0];
    [self.lock unlock];
    return data;
}

- (void)appendPCMData:(NSData *)data {
    if (data.length == 0) {
        return;
    }

    [self.lock lock];
    NSUInteger overflow = 0;
    if (self.pcmBuffer.length + data.length > self.maxBufferedBytes) {
        overflow = self.pcmBuffer.length + data.length - self.maxBufferedBytes;
    }
    if (overflow > 0 && overflow < self.pcmBuffer.length) {
        [self.pcmBuffer replaceBytesInRange:NSMakeRange(0, overflow) withBytes:NULL length:0];
    } else if (overflow >= self.pcmBuffer.length) {
        [self.pcmBuffer setLength:0];
    }
    [self.pcmBuffer appendData:data];
    [self.lock unlock];
}

- (void)updateSourceSampleRate:(int)sampleRate channels:(int)channels {
    if (sampleRate <= 0 || channels <= 0) {
        return;
    }

    [self.lock lock];
    self.sourceSampleRate = sampleRate;
    self.sourceChannels = channels;
    self.maxBufferedBytes = (NSUInteger)sampleRate * (NSUInteger)MAX(channels, 1) * 2 * 2;
    [self.lock unlock];
}

- (void)readerThreadMain {
    @autoreleasepool {
        while (YES) {
            [self loadPreferences];
            if (!self.enabled) {
                [NSThread sleepForTimeInterval:2.0];
                continue;
            }

            int fd = [self connectSocket];
            if (fd < 0) {
                [NSThread sleepForTimeInterval:1.0];
                continue;
            }

            if (self.verbose) {
                IVCAMLog(@"connected to %@:%d", self.host, self.port);
            }

            [self readHelloFromSocket:fd];
            [self readFramesFromSocket:fd];
            close(fd);

            if (self.verbose) {
                IVCAMLog(@"audio bridge disconnected");
            }
            [NSThread sleepForTimeInterval:1.0];
        }
    }
}

- (int)connectSocket {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)self.port);

    if (inet_pton(AF_INET, self.host.UTF8String, &addr.sin_addr) != 1) {
        close(fd);
        return -1;
    }

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }

    return fd;
}

- (BOOL)readFullyFromSocket:(int)fd buffer:(void *)buffer length:(NSUInteger)length {
    uint8_t *cursor = (uint8_t *)buffer;
    NSUInteger remaining = length;
    while (remaining > 0) {
        ssize_t got = recv(fd, cursor, remaining, 0);
        if (got <= 0) {
            return NO;
        }
        cursor += got;
        remaining -= (NSUInteger)got;
    }
    return YES;
}

- (void)readHelloFromSocket:(int)fd {
    NSMutableData *line = [NSMutableData data];
    uint8_t byte = 0;
    while (line.length < 4096) {
        ssize_t got = recv(fd, &byte, 1, 0);
        if (got <= 0) {
            return;
        }
        if (byte == '\n') {
            break;
        }
        [line appendBytes:&byte length:1];
    }

    NSString *hello = [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding];
    NSRange space = [hello rangeOfString:@" "];
    if (space.location == NSNotFound || space.location + 1 >= hello.length) {
        return;
    }

    NSString *jsonText = [hello substringFromIndex:space.location + 1];
    NSData *jsonData = [jsonText dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *metadata = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    if (![metadata isKindOfClass:[NSDictionary class]]) {
        return;
    }

    int sampleRate = [metadata[@"sample_rate"] respondsToSelector:@selector(intValue)] ? [metadata[@"sample_rate"] intValue] : 48000;
    int channels = [metadata[@"channels"] respondsToSelector:@selector(intValue)] ? [metadata[@"channels"] intValue] : 1;
    [self updateSourceSampleRate:sampleRate channels:channels];
}

- (void)readFramesFromSocket:(int)fd {
    while (YES) {
        IVCAMAudioFrameHeader header;
        if (![self readFullyFromSocket:fd buffer:&header length:sizeof(header)]) {
            return;
        }

        if (memcmp(header.magic, IVCAM_AUDIO_MAGIC, 4) != 0) {
            return;
        }

        uint32_t payloadLength = CFSwapInt32LittleToHost(header.payloadLength);
        if (payloadLength == 0 || payloadLength > 262144) {
            return;
        }

        NSMutableData *payload = [NSMutableData dataWithLength:payloadLength];
        if (![self readFullyFromSocket:fd buffer:payload.mutableBytes length:payloadLength]) {
            return;
        }
        [self appendPCMData:payload];
    }
}

@end

static BOOL IVCAMASBDIsSupported(const AudioStreamBasicDescription *asbd) {
    if (!asbd) {
        return NO;
    }
    if (asbd->mFormatID != kAudioFormatLinearPCM) {
        return NO;
    }
    if ((asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0) {
        return NO;
    }
    if ((asbd->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0) {
        return NO;
    }
    if ((asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0) {
        return NO;
    }
    if (asbd->mBitsPerChannel != 16) {
        return NO;
    }
    if (asbd->mChannelsPerFrame < 1 || asbd->mChannelsPerFrame > 2) {
        return NO;
    }
    if (asbd->mBytesPerFrame != asbd->mChannelsPerFrame * 2) {
        return NO;
    }
    return YES;
}

static NSData *IVCAMConvertPCM(NSData *sourceData, UInt32 sourceChannels, UInt32 targetChannels, UInt32 sampleCount) {
    if (sourceChannels == targetChannels) {
        return sourceData;
    }

    const int16_t *source = (const int16_t *)sourceData.bytes;
    NSMutableData *converted = [NSMutableData dataWithLength:(NSUInteger)sampleCount * targetChannels * sizeof(int16_t)];
    int16_t *target = (int16_t *)converted.mutableBytes;

    if (sourceChannels == 1 && targetChannels == 2) {
        for (UInt32 i = 0; i < sampleCount; i++) {
            int16_t mono = source[i];
            target[i * 2] = mono;
            target[i * 2 + 1] = mono;
        }
        return converted;
    }

    if (sourceChannels == 2 && targetChannels == 1) {
        for (UInt32 i = 0; i < sampleCount; i++) {
            int32_t left = source[i * 2];
            int32_t right = source[i * 2 + 1];
            target[i] = (int16_t)((left + right) / 2);
        }
        return converted;
    }

    return nil;
}

static CMSampleBufferRef IVCAMCreateInjectedAudioSample(CMSampleBufferRef originalSampleBuffer) {
    if (!originalSampleBuffer) {
        return NULL;
    }

    IVCAMAudioBridgeClient *client = [IVCAMAudioBridgeClient sharedClient];
    [client ensureStarted];

    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(originalSampleBuffer);
    if (!formatDescription) {
        return NULL;
    }

    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
    if (!IVCAMASBDIsSupported(asbd)) {
        return NULL;
    }

    int sourceRate = [client currentSourceSampleRate];
    int sourceChannels = [client currentSourceChannels];
    if (sourceRate != (int)llround(asbd->mSampleRate)) {
        return NULL;
    }
    if (sourceChannels < 1 || sourceChannels > 2) {
        return NULL;
    }

    CMItemCount sampleCount = CMSampleBufferGetNumSamples(originalSampleBuffer);
    if (sampleCount <= 0 || sampleCount > 8192) {
        return NULL;
    }

    NSUInteger sourceByteCount = (NSUInteger)sampleCount * (NSUInteger)sourceChannels * sizeof(int16_t);
    NSData *sourcePCM = [client takePCMBytes:sourceByteCount];
    if (sourcePCM.length != sourceByteCount) {
        return NULL;
    }

    NSData *targetPCM = IVCAMConvertPCM(sourcePCM, (UInt32)sourceChannels, asbd->mChannelsPerFrame, (UInt32)sampleCount);
    if (!targetPCM) {
        return NULL;
    }

    void *pcmMemory = malloc(targetPCM.length);
    if (!pcmMemory) {
        return NULL;
    }
    memcpy(pcmMemory, targetPCM.bytes, targetPCM.length);

    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        pcmMemory,
        targetPCM.length,
        kCFAllocatorMalloc,
        NULL,
        0,
        targetPCM.length,
        0,
        &blockBuffer
    );
    if (status != noErr || !blockBuffer) {
        free(pcmMemory);
        return NULL;
    }

    CMSampleTimingInfo timing;
    timing.duration = CMSampleBufferGetDuration(originalSampleBuffer);
    if (!CMTIME_IS_VALID(timing.duration) || CMTIME_IS_INDEFINITE(timing.duration)) {
        timing.duration = CMTimeMake((int64_t)sampleCount, (int32_t)asbd->mSampleRate);
    }
    timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originalSampleBuffer);
    timing.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef injectedSampleBuffer = NULL;
    status = CMSampleBufferCreateReady(
        kCFAllocatorDefault,
        blockBuffer,
        formatDescription,
        sampleCount,
        1,
        &timing,
        0,
        NULL,
        &injectedSampleBuffer
    );
    CFRelease(blockBuffer);

    if (status != noErr) {
        return NULL;
    }

    return injectedSampleBuffer;
}

static void IVCAMCallOriginalAudioDelegate(id self, SEL _cmd, id output, CMSampleBufferRef sampleBuffer, id connection) {
    NSString *className = NSStringFromClass([self class]);
    NSValue *value = nil;
    @synchronized (gOriginalAudioDelegateIMPs) {
        value = gOriginalAudioDelegateIMPs[className];
    }

    IMP originalIMP = [value pointerValue];
    if (!originalIMP) {
        return;
    }

    ((void (*)(id, SEL, id, CMSampleBufferRef, id))originalIMP)(self, _cmd, output, sampleBuffer, connection);
}

static void IVCAMAudioCaptureOutputDidOutput(id self, SEL _cmd, id output, CMSampleBufferRef sampleBuffer, id connection) {
    CMSampleBufferRef injected = IVCAMCreateInjectedAudioSample(sampleBuffer);
    if (injected) {
        IVCAMCallOriginalAudioDelegate(self, _cmd, output, injected, connection);
        CFRelease(injected);
        return;
    }

    IVCAMCallOriginalAudioDelegate(self, _cmd, output, sampleBuffer, connection);
}

static void IVCAMHookAudioDelegateIfNeeded(id delegate) {
    if (!delegate) {
        return;
    }

    Class delegateClass = [delegate class];
    if (!delegateClass) {
        return;
    }

    SEL selector = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method method = class_getInstanceMethod(delegateClass, selector);
    if (!method) {
        return;
    }

    NSString *className = NSStringFromClass(delegateClass);
    @synchronized (gHookedAudioDelegateClasses) {
        if ([gHookedAudioDelegateClasses containsObject:className]) {
            return;
        }

        IMP originalIMP = NULL;
        MSHookMessageEx(delegateClass, selector, (IMP)IVCAMAudioCaptureOutputDidOutput, &originalIMP);
        if (originalIMP) {
            gOriginalAudioDelegateIMPs[className] = [NSValue valueWithPointer:originalIMP];
            [gHookedAudioDelegateClasses addObject:className];
            IVCAMLog(@"hooked audio delegate %@", className);
        }
    }
}

%hook AVCaptureAudioDataOutput

- (void)setSampleBufferDelegate:(id)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    IVCAMHookAudioDelegateIfNeeded(sampleBufferDelegate);
    [[IVCAMAudioBridgeClient sharedClient] ensureStarted];
    %orig(sampleBufferDelegate, sampleBufferCallbackQueue);
}

%end

%ctor {
    gHookedAudioDelegateClasses = [[NSMutableSet alloc] init];
    gOriginalAudioDelegateIMPs = [[NSMutableDictionary alloc] init];
    [[IVCAMAudioBridgeClient sharedClient] ensureStarted];
    IVCAMLog(@"loaded experimental audio companion; host defaults to 127.10.10.10:1936");
}

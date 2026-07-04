#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <unistd.h>

#define IVCAM_SAFE_PREFS @"/var/mobile/Library/Preferences/com.iosvcam.audiobridge.safe.plist"
#define IVCAM_SAFE_DISABLE_FLAG @"/var/mobile/Library/Preferences/com.iosvcam.audiobridge.safe.disabled"
#define IVCAM_SAFE_MAGIC "IAF1"

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
    if ([[NSFileManager defaultManager] fileExistsAtPath:IVCAM_SAFE_DISABLE_FLAG]) {
        self.enabled = NO;
        return;
    }

    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:IVCAM_SAFE_PREFS];
    self.enabled = [prefs[@"Enabled"] boolValue];
    NSString *host = prefs[@"Host"];
    NSNumber *port = prefs[@"Port"];
    NSNumber *sampleRate = prefs[@"SampleRate"];
    NSNumber *channels = prefs[@"Channels"];

    if (host.length > 0) self.host = host;
    if (port.intValue > 0) self.port = port.intValue;
    if (sampleRate.intValue > 0) self.sampleRate = sampleRate.intValue;
    if (channels.intValue == 1 || channels.intValue == 2) self.channels = channels.intValue;

    NSLog(@"[iOSVCAMAudioBridgeSafe] prefs enabled=%d host=%@ port=%d rate=%d channels=%d", self.enabled, self.host, self.port, self.sampleRate, self.channels);
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

                NSLog(@"[iOSVCAMAudioBridgeSafe] connected to %@:%d", self.host, self.port);

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
                NSLog(@"[iOSVCAMAudioBridgeSafe] bridge disconnected; retrying");
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
            NSLog(@"[iOSVCAMAudioBridgeSafe] hooked delegate %@", className);
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
        NSLog(@"[iOSVCAMAudioBridgeSafe] loaded into %@", bundleID);
        [[IVCAMSafeAudioClient sharedClient] reloadPrefs];
    }
}

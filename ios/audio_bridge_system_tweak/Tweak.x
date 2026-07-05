#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <substrate.h>
#import <fcntl.h>
#import <stdarg.h>
#import <stdint.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <time.h>
#import <unistd.h>

#import "../audio_bridge_common/AudioBridgeShared.h"

#define IVCAM_SYSTEM_HOOK_DISABLE_FLAG @"/var/mobile/Library/Preferences/com.iosvcam.audiobridge.system-hook.disabled"
#define IVCAM_SYSTEM_HOOK_LOG @"iOSVCAMAudioBridgeSystemHook.log"
#define IVCAM_SYSTEM_HOOK_TARGET_BUNDLE @"com.apple.mediaserverd"
#define IVCAM_SYSTEM_HOOK_TARGET_PROCESS @"mediaserverd"
#define IVCAM_SYSTEM_HOOK_STALE_US 1000000ull

static OSStatus (*gOriginalAudioUnitRender)(AudioUnit inUnit,
                                            AudioUnitRenderActionFlags *ioActionFlags,
                                            const AudioTimeStamp *inTimeStamp,
                                            UInt32 inOutputBusNumber,
                                            UInt32 inNumberFrames,
                                            AudioBufferList *ioData) = NULL;
static IVCAMAudioBridgeSharedState *gSharedState = NULL;
static size_t gSharedStateSize = 0;

static NSString *IVCAMSystemHookLogPath(void) {
    NSString *logsDir = @"/var/mobile/Library/Logs";
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:logsDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&error];
    if (!error) {
        return [logsDir stringByAppendingPathComponent:IVCAM_SYSTEM_HOOK_LOG];
    }

    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length > 0) {
        return [tmp stringByAppendingPathComponent:IVCAM_SYSTEM_HOOK_LOG];
    }
    return [@"/tmp" stringByAppendingPathComponent:IVCAM_SYSTEM_HOOK_LOG];
}

static BOOL IVCAMSystemHookPathExists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static void IVCAMSystemHookRotateIfNeeded(NSString *path) {
    NSDictionary<NSFileAttributeKey, id> *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSNumber *size = attrs[NSFileSize];
    if (size && [size unsignedLongLongValue] > 65536) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
}

static void IVCAMSystemHookLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = IVCAMSystemHookLogPath();
    IVCAMSystemHookRotateIfNeeded(path);

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:NO];
    } else {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        }
    }

    NSLog(@"[iOSVCAMAudioBridgeSystemHook] %@", message);
}

static uint32_t IVCAMSystemHookLoad32(const uint32_t *field) {
    return __atomic_load_n(field, __ATOMIC_ACQUIRE);
}

static uint64_t IVCAMSystemHookLoad64(const uint64_t *field) {
    return __atomic_load_n(field, __ATOMIC_ACQUIRE);
}

static uint64_t IVCAMSystemHookAdd64(uint64_t *field, uint64_t amount) {
    return __atomic_add_fetch(field, amount, __ATOMIC_RELEASE);
}

static uint64_t IVCAMSystemHookNowUS(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return ((uint64_t)ts.tv_sec * 1000000ull) + ((uint64_t)ts.tv_nsec / 1000ull);
}

static BOOL IVCAMSystemHookMapSharedState(void) {
    int fd = open(IVCAM_AB_SHARED_PATH, O_RDWR);
    if (fd < 0) {
        IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_SHARED_ABSENT path=%s", IVCAM_AB_SHARED_PATH);
        return NO;
    }

    size_t size = IVCAMAudioBridgeSharedSize();
    void *mapped = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) {
        IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_SHARED_MAP_FAILED path=%s", IVCAM_AB_SHARED_PATH);
        return NO;
    }

    IVCAMAudioBridgeSharedState *shared = (IVCAMAudioBridgeSharedState *)mapped;
    if (IVCAMSystemHookLoad32(&shared->magic) != IVCAM_AB_SHARED_MAGIC ||
        IVCAMSystemHookLoad32(&shared->version) != IVCAM_AB_SHARED_VERSION ||
        IVCAMSystemHookLoad32(&shared->total_size) != (uint32_t)size) {
        munmap(mapped, size);
        IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_SHARED_VERSION_MISMATCH");
        return NO;
    }

    gSharedState = shared;
    gSharedStateSize = size;
    IVCAMSystemHookAdd64(&shared->input_render_seen, 1);
    IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_SHARED_READY capacity=%u state=%u sequence=%llu hookLoads=%llu",
                       IVCAMSystemHookLoad32(&shared->ring_capacity_bytes),
                       IVCAMSystemHookLoad32(&shared->state),
                       IVCAMSystemHookLoad64(&shared->ring_write_sequence),
                       IVCAMSystemHookLoad64(&shared->input_render_seen));
    return YES;
}

static BOOL IVCAMSystemHookSharedReady(IVCAMAudioBridgeSharedState *shared) {
    if (!shared) return NO;
    if (IVCAMSystemHookLoad32(&shared->magic) != IVCAM_AB_SHARED_MAGIC) return NO;
    if (IVCAMSystemHookLoad32(&shared->version) != IVCAM_AB_SHARED_VERSION) return NO;
    if (IVCAMSystemHookLoad32(&shared->state) != IVCAM_AB_STATE_STREAMING) return NO;
    if (IVCAMSystemHookLoad32(&shared->format.sample_format) != IVCAM_AB_SAMPLE_FORMAT_S16LE) return NO;
    uint64_t updated = IVCAMSystemHookLoad64(&shared->updated_at_us);
    uint64_t now = IVCAMSystemHookNowUS();
    if (now > updated && now - updated > IVCAM_SYSTEM_HOOK_STALE_US) {
        IVCAMSystemHookAdd64(&shared->stale_reads, 1);
        return NO;
    }
    return YES;
}

static int16_t IVCAMSystemHookReadS16(const IVCAMAudioBridgeSharedState *shared,
                                      uint32_t start,
                                      uint32_t byteOffset) {
    uint32_t capacity = IVCAMSystemHookLoad32(&shared->ring_capacity_bytes);
    if (capacity < 2) return 0;
    uint32_t pos = (start + byteOffset) % capacity;
    uint8_t lo = shared->ring[pos];
    uint8_t hi = shared->ring[(pos + 1) % capacity];
    return (int16_t)((uint16_t)lo | ((uint16_t)hi << 8));
}

static int16_t IVCAMSystemHookSampleAt(const IVCAMAudioBridgeSharedState *shared,
                                       uint32_t start,
                                       UInt32 frame,
                                       UInt32 channel,
                                       UInt32 sourceChannels,
                                       UInt32 targetChannels) {
    UInt32 sourceChannel = 0;
    if (sourceChannels == targetChannels) {
        sourceChannel = channel;
    } else if (sourceChannels == 2 && targetChannels == 1) {
        int16_t left = IVCAMSystemHookReadS16(shared, start, (frame * 2u) * 2u);
        int16_t right = IVCAMSystemHookReadS16(shared, start, (frame * 2u + 1u) * 2u);
        return (int16_t)(((int32_t)left + (int32_t)right) / 2);
    }
    return IVCAMSystemHookReadS16(shared, start, (frame * sourceChannels + sourceChannel) * 2u);
}

static BOOL IVCAMSystemHookFillBuffers(AudioBufferList *ioData,
                                       UInt32 frames,
                                       const AudioStreamBasicDescription *asbd,
                                       IVCAMAudioBridgeSharedState *shared) {
    if (!ioData || !asbd || !shared || frames == 0) return NO;
    UInt32 sourceChannels = IVCAMSystemHookLoad32(&shared->format.channels);
    UInt32 targetChannels = asbd->mChannelsPerFrame;
    BOOL isNonInterleaved = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    if (targetChannels == 0 && isNonInterleaved) targetChannels = ioData->mNumberBuffers;
    if (!((sourceChannels == 1 || sourceChannels == 2) && (targetChannels == 1 || targetChannels == 2))) {
        IVCAMSystemHookAdd64(&shared->unsupported_formats, 1);
        return NO;
    }
    if (asbd->mSampleRate != (Float64)IVCAMSystemHookLoad32(&shared->format.sample_rate) ||
        asbd->mFormatID != kAudioFormatLinearPCM) {
        IVCAMSystemHookAdd64(&shared->unsupported_formats, 1);
        return NO;
    }

    BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL isSignedInt = (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    if (!((isFloat && asbd->mBitsPerChannel == 32) || (isSignedInt && asbd->mBitsPerChannel == 16))) {
        IVCAMSystemHookAdd64(&shared->unsupported_formats, 1);
        return NO;
    }

    uint32_t bytesNeeded = frames * sourceChannels * 2u;
    uint32_t capacity = IVCAMSystemHookLoad32(&shared->ring_capacity_bytes);
    uint32_t valid = IVCAMSystemHookLoad32(&shared->ring_valid_bytes);
    uint32_t writeOffset = IVCAMSystemHookLoad32(&shared->ring_write_offset);
    if (capacity == 0 || bytesNeeded == 0 || bytesNeeded > capacity || valid < bytesNeeded) {
        IVCAMSystemHookAdd64(&shared->underruns, 1);
        return NO;
    }
    uint32_t start = (writeOffset + capacity - bytesNeeded) % capacity;

    if (isSignedInt && !isNonInterleaved && sourceChannels == targetChannels && ioData->mNumberBuffers >= 1 && ioData->mBuffers[0].mData) {
        uint32_t writable = MIN((uint32_t)ioData->mBuffers[0].mDataByteSize, bytesNeeded);
        uint32_t first = writable;
        if (start + writable > capacity) first = capacity - start;
        memcpy(ioData->mBuffers[0].mData, shared->ring + start, first);
        if (first < writable) {
            memcpy((uint8_t *)ioData->mBuffers[0].mData + first, shared->ring, writable - first);
        }
        ioData->mBuffers[0].mDataByteSize = writable;
        return YES;
    }

    if (isFloat) {
        if (isNonInterleaved) {
            if (ioData->mNumberBuffers < targetChannels) return NO;
            for (UInt32 ch = 0; ch < targetChannels; ch++) {
                if (!ioData->mBuffers[ch].mData) return NO;
                float *out = (float *)ioData->mBuffers[ch].mData;
                UInt32 writableFrames = MIN(frames, ioData->mBuffers[ch].mDataByteSize / sizeof(float));
                for (UInt32 i = 0; i < writableFrames; i++) {
                    int16_t sample = IVCAMSystemHookSampleAt(shared, start, i, ch, sourceChannels, targetChannels);
                    out[i] = (float)sample / 32768.0f;
                }
                ioData->mBuffers[ch].mDataByteSize = writableFrames * sizeof(float);
            }
            return YES;
        }
        if (ioData->mNumberBuffers < 1 || !ioData->mBuffers[0].mData) return NO;
        float *out = (float *)ioData->mBuffers[0].mData;
        UInt32 writableSamples = MIN(frames * targetChannels, ioData->mBuffers[0].mDataByteSize / sizeof(float));
        for (UInt32 i = 0; i < writableSamples; i++) {
            UInt32 frame = i / targetChannels;
            UInt32 ch = i % targetChannels;
            int16_t sample = IVCAMSystemHookSampleAt(shared, start, frame, ch, sourceChannels, targetChannels);
            out[i] = (float)sample / 32768.0f;
        }
        ioData->mBuffers[0].mDataByteSize = writableSamples * sizeof(float);
        return YES;
    }

    if (isSignedInt && isNonInterleaved) {
        if (ioData->mNumberBuffers < targetChannels) return NO;
        for (UInt32 ch = 0; ch < targetChannels; ch++) {
            if (!ioData->mBuffers[ch].mData) return NO;
            int16_t *out = (int16_t *)ioData->mBuffers[ch].mData;
            UInt32 writableFrames = MIN(frames, ioData->mBuffers[ch].mDataByteSize / sizeof(int16_t));
            for (UInt32 i = 0; i < writableFrames; i++) {
                out[i] = IVCAMSystemHookSampleAt(shared, start, i, ch, sourceChannels, targetChannels);
            }
            ioData->mBuffers[ch].mDataByteSize = writableFrames * sizeof(int16_t);
        }
        return YES;
    }

    return NO;
}

static OSStatus IVCAMSystemHookAudioUnitRender(AudioUnit inUnit,
                                               AudioUnitRenderActionFlags *ioActionFlags,
                                               const AudioTimeStamp *inTimeStamp,
                                               UInt32 inOutputBusNumber,
                                               UInt32 inNumberFrames,
                                               AudioBufferList *ioData) {
    OSStatus status = gOriginalAudioUnitRender ? gOriginalAudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData) : noErr;
    if (status != noErr || !ioData) return status;

    IVCAMAudioBridgeSharedState *shared = gSharedState;
    if (!IVCAMSystemHookSharedReady(shared)) return status;
    IVCAMSystemHookAdd64(&shared->render_calls, 1);
    if (inOutputBusNumber > 1) return status;

    AudioStreamBasicDescription asbd;
    UInt32 size = sizeof(asbd);
    memset(&asbd, 0, sizeof(asbd));
    OSStatus formatStatus = AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inOutputBusNumber, &asbd, &size);
    if (formatStatus != noErr) {
        size = sizeof(asbd);
        formatStatus = AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inOutputBusNumber, &asbd, &size);
    }
    if (formatStatus != noErr) {
        IVCAMSystemHookAdd64(&shared->unsupported_formats, 1);
        return status;
    }

    if (IVCAMSystemHookFillBuffers(ioData, inNumberFrames, &asbd, shared)) {
        IVCAMSystemHookAdd64(&shared->replacement_count, 1);
    }
    return status;
}

__attribute__((constructor)) static void IVCAMSystemHookConstructor(void) {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *processName = [[NSProcessInfo processInfo] processName] ?: @"";
        NSString *executablePath = [[NSProcessInfo processInfo] arguments].firstObject ?: @"";
        BOOL targetProcess = [bundleID isEqualToString:IVCAM_SYSTEM_HOOK_TARGET_BUNDLE] || [processName isEqualToString:IVCAM_SYSTEM_HOOK_TARGET_PROCESS];

        IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_LOADED bundle=%@ process=%@ executable=%@ uid=%d euid=%d target=%d",
                           bundleID,
                           processName,
                           executablePath,
                           getuid(),
                           geteuid(),
                           targetProcess);

        IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_PATHS tweakinject=%d autopatches=%d pkgmirror=%d disabled=%d shared=%d",
                           IVCAMSystemHookPathExists(@"/usr/lib/TweakInject"),
                           IVCAMSystemHookPathExists(@"/usr/lib/DynamicPatches/AutoPatches.dylib"),
                           IVCAMSystemHookPathExists(@"/var/mobile/Library/pkgmirror/Library/MobileSubstrate/DynamicLibraries"),
                           IVCAMSystemHookPathExists(IVCAM_SYSTEM_HOOK_DISABLE_FLAG),
                           IVCAMSystemHookPathExists(@IVCAM_AB_SHARED_PATH));

        if (IVCAMSystemHookPathExists(IVCAM_SYSTEM_HOOK_DISABLE_FLAG)) {
            IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_DISABLED by file flag");
            return;
        }

        if (!targetProcess) {
            IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_INACTIVE not media target");
            return;
        }

        IVCAMSystemHookMapSharedState();
        MSHookFunction((void *)AudioUnitRender, (void *)IVCAMSystemHookAudioUnitRender, (void **)&gOriginalAudioUnitRender);
        IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_READY AudioUnitRender hook installed; network remains in daemon");
        IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_PHASE2 active shared-ring replacement enabled fail-open=1");
        IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_REPLACED counter increments only after supported input renders");
        (void)gSharedStateSize;
    }
}

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
#import <unistd.h>

#import "../audio_bridge_common/AudioBridgeShared.h"

#define IVCAM_SYSTEM_HOOK_DISABLE_FLAG @"/var/mobile/Library/Preferences/com.iosvcam.audiobridge.system-hook.disabled"
#define IVCAM_SYSTEM_HOOK_LOG @"iOSVCAMAudioBridgeSystemHook.log"
#define IVCAM_SYSTEM_HOOK_TARGET_BUNDLE @"com.apple.mediaserverd"
#define IVCAM_SYSTEM_HOOK_TARGET_PROCESS @"mediaserverd"

static OSStatus (*gOriginalAudioUnitRender)(AudioUnit inUnit,
                                            AudioUnitRenderActionFlags *ioActionFlags,
                                            const AudioTimeStamp *inTimeStamp,
                                            UInt32 inOutputBusNumber,
                                            UInt32 inNumberFrames,
                                            AudioBufferList *ioData) = NULL;
static const IVCAMAudioBridgeSharedState *gSharedState = NULL;
static size_t gSharedStateSize = 0;
static uint64_t gLocalRenderCalls = 0;
static uint64_t gLastObservedSequence = 0;

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

static BOOL IVCAMSystemHookMapSharedState(void) {
    int fd = open(IVCAM_AB_SHARED_PATH, O_RDONLY);
    if (fd < 0) {
        IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_SHARED_ABSENT path=%s", IVCAM_AB_SHARED_PATH);
        return NO;
    }

    size_t size = IVCAMAudioBridgeSharedSize();
    void *mapped = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) {
        IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_SHARED_MAP_FAILED path=%s", IVCAM_AB_SHARED_PATH);
        return NO;
    }

    const IVCAMAudioBridgeSharedState *shared = (const IVCAMAudioBridgeSharedState *)mapped;
    if (IVCAMSystemHookLoad32(&shared->magic) != IVCAM_AB_SHARED_MAGIC ||
        IVCAMSystemHookLoad32(&shared->version) != IVCAM_AB_SHARED_VERSION ||
        IVCAMSystemHookLoad32(&shared->total_size) != (uint32_t)size) {
        munmap(mapped, size);
        IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_SHARED_VERSION_MISMATCH");
        return NO;
    }

    gSharedState = shared;
    gSharedStateSize = size;
    IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_SHARED_READY capacity=%u", IVCAMSystemHookLoad32(&shared->ring_capacity_bytes));
    return YES;
}

static BOOL IVCAMSystemHookSharedLooksReady(const IVCAMAudioBridgeSharedState *shared) {
    if (!shared) return NO;
    if (IVCAMSystemHookLoad32(&shared->magic) != IVCAM_AB_SHARED_MAGIC) return NO;
    if (IVCAMSystemHookLoad32(&shared->version) != IVCAM_AB_SHARED_VERSION) return NO;
    if (IVCAMSystemHookLoad32(&shared->ring_capacity_bytes) == 0) return NO;
    return YES;
}

static OSStatus IVCAMSystemHookAudioUnitRender(AudioUnit inUnit,
                                               AudioUnitRenderActionFlags *ioActionFlags,
                                               const AudioTimeStamp *inTimeStamp,
                                               UInt32 inOutputBusNumber,
                                               UInt32 inNumberFrames,
                                               AudioBufferList *ioData) {
    OSStatus status = gOriginalAudioUnitRender ? gOriginalAudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData) : noErr;
    if (status != noErr || !ioData) return status;

    gLocalRenderCalls++;
    const IVCAMAudioBridgeSharedState *shared = gSharedState;
    if (IVCAMSystemHookSharedLooksReady(shared)) {
        gLastObservedSequence = IVCAMSystemHookLoad64(&shared->ring_write_sequence);
    }

    (void)inUnit;
    (void)ioActionFlags;
    (void)inTimeStamp;
    (void)inOutputBusNumber;
    (void)inNumberFrames;
    (void)gLastObservedSequence;
    return status;
}

%ctor {
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
        IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_READY AudioUnitRender hook installed");
        IVCAMSystemHookLog(@"AUDIO_SYSTEM_HOOK_PASSIVE phase=1 no audio writes replacement=off");
    }
}

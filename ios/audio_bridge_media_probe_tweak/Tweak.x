#import <Foundation/Foundation.h>
#import <unistd.h>
#import <stdarg.h>

#define IVCAM_MEDIA_PROBE_DISABLE_FLAG @"/var/mobile/Library/Preferences/com.iosvcam.audiobridge.media-probe.disabled"
#define IVCAM_MEDIA_PROBE_LOG @"iOSVCAMAudioBridgeMediaProbe.log"
#define IVCAM_MEDIA_PROBE_TARGET_BUNDLE @"com.apple.mediaserverd"
#define IVCAM_MEDIA_PROBE_TARGET_PROCESS @"mediaserverd"

static NSString *IVCAMMediaProbeLogPath(void) {
    NSString *logsDir = @"/var/mobile/Library/Logs";
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:logsDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&error];
    if (!error) {
        return [logsDir stringByAppendingPathComponent:IVCAM_MEDIA_PROBE_LOG];
    }

    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length > 0) {
        return [tmp stringByAppendingPathComponent:IVCAM_MEDIA_PROBE_LOG];
    }
    return [@"/tmp" stringByAppendingPathComponent:IVCAM_MEDIA_PROBE_LOG];
}

static BOOL IVCAMMediaProbePathExists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static void IVCAMMediaProbeRotateIfNeeded(NSString *path) {
    NSDictionary<NSFileAttributeKey, id> *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSNumber *size = attrs[NSFileSize];
    if (size && [size unsignedLongLongValue] > 65536) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
}

static void IVCAMMediaProbeLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = IVCAMMediaProbeLogPath();
    IVCAMMediaProbeRotateIfNeeded(path);

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

    NSLog(@"[iOSVCAMAudioBridgeMediaProbe] %@", message);
}

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *processName = [[NSProcessInfo processInfo] processName] ?: @"";
        NSString *executablePath = [[NSProcessInfo processInfo] arguments].firstObject ?: @"";
        BOOL targetProcess = [bundleID isEqualToString:IVCAM_MEDIA_PROBE_TARGET_BUNDLE] || [processName isEqualToString:IVCAM_MEDIA_PROBE_TARGET_PROCESS];

        IVCAMMediaProbeLog(@"MEDIA_PROBE_LOADED bundle=%@ process=%@ executable=%@ uid=%d euid=%d target=%d",
                           bundleID,
                           processName,
                           executablePath,
                           getuid(),
                           geteuid(),
                           targetProcess);

        IVCAMMediaProbeLog(@"MEDIA_PROBE_PATHS tweakinject=%d autopatches=%d pkgmirror=%d disabled=%d",
                           IVCAMMediaProbePathExists(@"/usr/lib/TweakInject"),
                           IVCAMMediaProbePathExists(@"/usr/lib/DynamicPatches/AutoPatches.dylib"),
                           IVCAMMediaProbePathExists(@"/var/mobile/Library/pkgmirror/Library/MobileSubstrate/DynamicLibraries"),
                           IVCAMMediaProbePathExists(IVCAM_MEDIA_PROBE_DISABLE_FLAG));

        if (IVCAMMediaProbePathExists(IVCAM_MEDIA_PROBE_DISABLE_FLAG)) {
            IVCAMMediaProbeLog(@"MEDIA_PROBE_DISABLED by file flag");
            return;
        }

        if (!targetProcess) {
            IVCAMMediaProbeLog(@"MEDIA_PROBE_INACTIVE not media target");
            return;
        }

        IVCAMMediaProbeLog(@"MEDIA_PROBE_PASSIVE no audio hooks installed; no audio replacement active");
    }
}

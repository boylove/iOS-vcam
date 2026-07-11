#import "VCamConfig.h"
#import "VCamLog.h"

// mediaserverd's sandbox blocks /var/mobile, so the primary config + kill-switch
// live in /var/tmp (which mediaserverd can read — the audio system hook uses it).
// /var/mobile is kept as a fallback for app-level contexts / the launcher's model.
// mediaserverd's sandbox is restrictive but allows /var/mobile/Media (the
// media store it manages — the closed vcamera reads /var/mobile/Media/vcamera.txt
// from here). /var/mobile proper and /var/tmp are blocked for mediaserverd, so
// Media is listed first; the others cover app-level contexts.
static NSArray<NSString *> *VCamConfigPaths(void) {
    return @[ @"/var/mobile/Media/vc.plist",
              @"/var/mobile/Media/OpenVCam/vc.plist",
              @"/var/tmp/vc.plist",
              @"/var/mobile/vc.plist",
              @"/usr/lib/TweakInject/vc.plist" ];
}
static NSArray<NSString *> *VCamDisablePaths(void) {
    return @[ @"/var/mobile/Media/vc.disabled",
              @"/var/tmp/vc.disabled",
              @"/var/mobile/vc.disabled" ];
}

#define VCAM_DEFAULT_RTMP @"rtmp://127.10.10.10:1935/live/srs"

@interface VCamConfig ()
@property (atomic, readwrite) BOOL enabled;
@property (atomic, copy, readwrite) NSString *rtmpURL;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, copy) NSString *lastSignature;
@end

@implementation VCamConfig

+ (instancetype)shared {
    static VCamConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[VCamConfig alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _enabled = NO;
        _rtmpURL = VCAM_DEFAULT_RTMP;
        [self reloadNow];
        [self startTimer];
    }
    return self;
}

- (void)startTimer {
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(1.5 * NSEC_PER_SEC),
                              (uint64_t)(0.5 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf reloadNow]; });
    dispatch_resume(_timer);
}

- (void)probePathsOnce {
#if VCAM_DEBUG
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *p in VCamConfigPaths()) {
            BOOL exists = [fm fileExistsAtPath:p];
            BOOL readable = [NSDictionary dictionaryWithContentsOfFile:p] != nil;
            VCamDebugLog(@"probe %@ exists=%d readable=%d", p, exists, readable);
        }
    });
#endif
}

- (void)reloadNow {
    [self probePathsOnce];
    NSFileManager *fm = [NSFileManager defaultManager];

    // Kill switch (checked first): any readable disable flag -> pass-through.
    for (NSString *path in VCamDisablePaths()) {
        if ([fm fileExistsAtPath:path]) {
            if (self.enabled) VCamLog(@"disabled by %@", path);
            self.enabled = NO;
            return;
        }
    }

    // First readable config file wins.
    NSDictionary *plist = nil;
    NSString *source = nil;
    for (NSString *path in VCamConfigPaths()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (d) { plist = d; source = path; break; }
    }

    id enabledValue = plist[@"enabled"] ?: plist[@"Enabled"];
    BOOL enabled = [enabledValue respondsToSelector:@selector(boolValue)]
                       ? [enabledValue boolValue] : YES;   // default on

    id rtmpValue = plist[@"rtmp"] ?: plist[@"Rtmp"] ?: plist[@"link"];
    NSString *rtmpURL = VCAM_DEFAULT_RTMP;
    if ([rtmpValue isKindOfClass:[NSString class]] && [rtmpValue length] > 0) {
        rtmpURL = [rtmpValue copy];
    }

    self.enabled = enabled;
    self.rtmpURL = rtmpURL;

    // Log only when something changes, so it never spams. NO mirror/rotation knobs: the
    // camera-overwrite path rotates a fixed CCW90 (== create90ImageBuffer: 0x82b48) and never
    // flips (the front selfie mirror is the downstream pipeline's job), exactly like the closed
    // vcamera — there is nothing for a user rotation/mirror setting to drive on that path.
    NSString *sig = [NSString stringWithFormat:@"%@|%d|%@",
                     source ?: @"defaults", enabled, rtmpURL];
    if (![sig isEqualToString:self.lastSignature]) {
        self.lastSignature = sig;
        VCamLog(@"config source=%@ enabled=%d url=%@",
                source ?: @"defaults", enabled, rtmpURL);
    }
}

@end

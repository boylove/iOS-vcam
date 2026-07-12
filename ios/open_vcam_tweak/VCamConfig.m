#import "VCamConfig.h"
#import "VCamControlChannel.h"
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
@property (atomic, readwrite) BOOL replaceVideo;
@property (atomic, readwrite) BOOL replaceAudio;
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
        _replaceVideo = YES;
        _replaceAudio = YES;
        [self reloadNow];
        [self startTimer];
        // Instant apply: re-read the moment the floating panel publishes a change,
        // instead of waiting for the next 1.5s poll tick.
        __weak typeof(self) weakSelf = self;
        VCamControlObserve(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                           ^{ [weakSelf reloadNow]; });
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

    // Sub-toggles from the floating panel (default ON, faithful to the pre-panel
    // behaviour where the whole tweak was on/off as a unit).
    id videoValue = plist[@"replaceVideo"] ?: plist[@"ReplaceVideo"];
    BOOL replaceVideo = [videoValue respondsToSelector:@selector(boolValue)]
                            ? [videoValue boolValue] : YES;
    id audioValue = plist[@"replaceAudio"] ?: plist[@"ReplaceAudio"];
    BOOL replaceAudio = [audioValue respondsToSelector:@selector(boolValue)]
                            ? [audioValue boolValue] : YES;

    // The live Darwin-notify state wins for the TOGGLES when the panel has published
    // this boot: it reaches sandboxes the file can't (TikTok) and applies instantly,
    // and is what makes the switches hot even where the file write is blocked. The URL
    // stays file-only (a 64-bit state can't carry a string), so mediaserverd keeps
    // reading it here. When no state was published, keep the file/compiled values.
    BOOL sEnabled = enabled, sVideo = replaceVideo, sAudio = replaceAudio;
    NSString *toggleSrc = @"file";
    if (VCamControlReadState(&sEnabled, &sVideo, &sAudio)) {
        enabled = sEnabled; replaceVideo = sVideo; replaceAudio = sAudio;
        toggleSrc = @"notify";
    }

    self.enabled = enabled;
    self.rtmpURL = rtmpURL;
    self.replaceVideo = replaceVideo;
    self.replaceAudio = replaceAudio;

    // Log only when something changes, so it never spams. NO mirror/rotation knobs: the
    // camera-overwrite path rotates a fixed CCW90 (== create90ImageBuffer: 0x82b48) and never
    // flips (the front selfie mirror is the downstream pipeline's job), exactly like the closed
    // vcamera — there is nothing for a user rotation/mirror setting to drive on that path.
    NSString *sig = [NSString stringWithFormat:@"%@|%d|%@|v%d|a%d|%@",
                     source ?: @"defaults", enabled, rtmpURL,
                     replaceVideo, replaceAudio, toggleSrc];
    if (![sig isEqualToString:self.lastSignature]) {
        self.lastSignature = sig;
        VCamLog(@"config source=%@ enabled=%d url=%@ replaceVideo=%d replaceAudio=%d toggles=%@",
                source ?: @"defaults", enabled, rtmpURL,
                replaceVideo, replaceAudio, toggleSrc);
    }
}

@end

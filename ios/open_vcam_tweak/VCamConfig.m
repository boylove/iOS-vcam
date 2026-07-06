#import "VCamConfig.h"

#define VCAM_PLIST_PATH   @"/var/mobile/vc.plist"
#define VCAM_DISABLE_FLAG @"/var/mobile/vc.disabled"
#define VCAM_DEFAULT_RTMP @"rtmp://127.10.10.10:1935/live/srs"

@interface VCamConfig ()
@property (atomic, readwrite) BOOL enabled;
@property (atomic, copy, readwrite) NSString *rtmpURL;
@property (atomic, readwrite) BOOL mirror;
@property (atomic, readwrite) NSInteger rotation;
@property (nonatomic, strong) dispatch_source_t timer;
@end

@implementation VCamConfig

+ (instancetype)shared {
    static VCamConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamConfig alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _enabled = NO;
        _rtmpURL = VCAM_DEFAULT_RTMP;
        _mirror = NO;
        _rotation = 0;
        [self reloadNow];
        [self startTimer];
    }
    return self;
}

- (void)startTimer {
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    // Poll every 1.5s; leeway 0.5s to keep it cheap.
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(1.5 * NSEC_PER_SEC),
                              (uint64_t)(0.5 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf reloadNow]; });
    dispatch_resume(_timer);
}

- (void)reloadNow {
    // Kill switch: presence of the flag file forces a hard pass-through.
    if ([[NSFileManager defaultManager] fileExistsAtPath:VCAM_DISABLE_FLAG]) {
        self.enabled = NO;
        return;
    }

    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:VCAM_PLIST_PATH];

    // Default enabled=YES when the key is absent so a bare {rtmp=...} plist works.
    id enabledValue = plist[@"enabled"] ?: plist[@"Enabled"];
    BOOL enabled = [enabledValue respondsToSelector:@selector(boolValue)]
                       ? [enabledValue boolValue] : YES;

    id rtmpValue = plist[@"rtmp"] ?: plist[@"Rtmp"] ?: plist[@"link"];
    NSString *rtmpURL = VCAM_DEFAULT_RTMP;
    if ([rtmpValue isKindOfClass:[NSString class]] && [rtmpValue length] > 0) {
        rtmpURL = [rtmpValue copy];
    }

    id mirrorValue = plist[@"mirror"] ?: plist[@"Mirror"];
    BOOL mirror = [mirrorValue respondsToSelector:@selector(boolValue)]
                      ? [mirrorValue boolValue] : NO;

    id rotationValue = plist[@"rotation"] ?: plist[@"Rotation"];
    NSInteger rotation = [rotationValue respondsToSelector:@selector(integerValue)]
                             ? [rotationValue integerValue] : 0;
    if (rotation != 0 && rotation != 90 && rotation != 180 && rotation != 270) {
        rotation = 0;
    }

    self.enabled = enabled;
    self.rtmpURL = rtmpURL;
    self.mirror = mirror;
    self.rotation = rotation;
}

@end

// ---------------------------------------------------------------------------
// OpenVCam — SpringBoard floating control panel.
//
// A draggable floating button that lives in SpringBoard and therefore floats
// OVER every app (its window sits at an extreme window level). Tapping it opens
// a small settings card:
//   * RTMP pull URL      (default rtmp://127.10.10.10:1935/live/srs)
//   * 替换视频 switch     (replace the camera video with the OBS frame)
//   * 替换音频 switch     (replace the microphone with the OBS audio)
//   * 保存 button         (apply — everything is HOT, no respring)
//
// Hot control across sandboxes (see VCamControlChannel.h): Save writes the RTMP
// URL + toggles to /var/mobile/Media/vc.plist (mediaserverd reads it within its
// 1.5s poll) AND publishes the toggles on the Darwin-notify bus, which reaches
// mediaserverd instantly and TikTok (whose sandbox cannot read the file at all).
//
// SAFETY. This is the only part of OpenVCam that runs inside SpringBoard, so it
// is deliberately minimal and defensive: it swizzles nothing, builds its UI only
// after a foreground scene exists, wraps everything in @try/@catch, and fails
// open (no window) on any error — a failure can at most cost a respring, never a
// boot loop. To disable JUST the panel without uninstalling, create the file
// /var/mobile/Media/vcam_nopanel (e.g. via Filza) and respring.
// ---------------------------------------------------------------------------
#import <UIKit/UIKit.h>
#import "VCamControlChannel.h"
#import "VCamLog.h"

#define VCAM_PANEL_DEFAULT_RTMP @"rtmp://127.10.10.10:1935/live/srs"
#define VCAM_PANEL_DISABLE_FILE @"/var/mobile/Media/vcam_nopanel"

// Where SpringBoard writes the config. Highest-priority first, matching VCamConfig's
// read order so mediaserverd picks up the SAME file. /var/mobile/Media is the one path
// mediaserverd's sandbox can read; the others are best-effort mirrors. (SpringBoard on
// RootHide famously cannot write /var/mobile/vc.plist — hence Media is primary.)
static NSArray<NSString *> *VCamPanelWritePaths(void) {
    return @[ @"/var/mobile/Media/vc.plist",
              @"/var/mobile/Media/OpenVCam/vc.plist",
              @"/var/mobile/vc.plist",
              @"/var/tmp/vc.plist" ];
}
// A write to any of these reaches mediaserverd (its sandbox allows the Media store), so
// the RTMP URL (which the notify bus can't carry) takes effect there.
static BOOL VCamPathReachesMediaserverd(NSString *path) {
    return [path hasPrefix:@"/var/mobile/Media/"];
}

#pragma mark - Passthrough window

// Touches on empty space fall through to the app below; only the button and (when
// open) the settings card are interactive. Standard AssistiveTouch-style overlay.
@interface VCamPassWindow : UIWindow
@property (nonatomic, weak) UIView *passthroughRootView;
@end
@implementation VCamPassWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.passthroughRootView) return nil;   // empty area -> pass through
    return v;
}
@end

#pragma mark - Controller

@interface VCamPanelController : NSObject <UITextFieldDelegate>
@property (nonatomic, strong) VCamPassWindow *window;
@property (nonatomic, strong) UIView *fab;            // floating button
@property (nonatomic, strong) UIView *backdrop;       // dim + tap-to-close (panel open only)
@property (nonatomic, strong) UIView *card;           // settings card
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UISwitch *videoSwitch;
@property (nonatomic, strong) UISwitch *audioSwitch;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, assign) BOOL open;
@property (nonatomic, assign) int retries;
+ (instancetype)shared;
- (void)installWhenReady;
@end

@implementation VCamPanelController

+ (instancetype)shared {
    static VCamPanelController *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [[VCamPanelController alloc] init]; });
    return c;
}

// Build the window once a foreground scene exists; retry a few times if SpringBoard's
// scene isn't connected yet at launch.
- (void)installWhenReady {
    @try {
        if (self.window) return;
        UIWindowScene *scene = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class]) {
                scene = (UIWindowScene *)s;
                if (s.activationState == UISceneActivationStateForegroundActive) break;
            }
        }
        if (!scene) {
            if (self.retries++ < 30) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ [self installWhenReady]; });
            }
            return;
        }
        [self buildUIWithScene:scene];
        VCamLog(@"panel: floating button installed");
    } @catch (NSException *e) {
        VCamLog(@"panel: install exception %@ — inactive", e);
    }
}

- (void)buildUIWithScene:(UIWindowScene *)scene {
    CGRect bounds = scene.screen ? scene.screen.bounds : UIScreen.mainScreen.bounds;
    if (CGRectIsEmpty(bounds)) bounds = UIScreen.mainScreen.bounds;

    VCamPassWindow *w = [[VCamPassWindow alloc] initWithWindowScene:scene];
    w.frame = bounds;
    w.windowLevel = (UIWindowLevel)100000000;   // above apps, alerts, the status bar
    w.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = vc;
    w.passthroughRootView = vc.view;
    w.hidden = NO;                               // visible, but NOT key until the panel opens
    self.window = w;

    // --- Floating button (draggable) ---
    CGFloat sz = 58.0;
    UIView *fab = [[UIView alloc] initWithFrame:CGRectMake(bounds.size.width - sz - 12,
                                                           bounds.size.height * 0.42, sz, sz)];
    fab.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    fab.layer.cornerRadius = sz / 2.0;
    fab.layer.borderWidth = 1.0;
    fab.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
    fab.clipsToBounds = YES;
    UILabel *icon = [[UILabel alloc] initWithFrame:fab.bounds];
    icon.text = @"🎥";
    icon.font = [UIFont systemFontOfSize:28];
    icon.textAlignment = NSTextAlignmentCenter;
    [fab addSubview:icon];
    [fab addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)]];
    [fab addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)]];
    [vc.view addSubview:fab];
    self.fab = fab;

    [self buildCardInView:vc.view bounds:bounds];
}

- (void)buildCardInView:(UIView *)root bounds:(CGRect)bounds {
    // Dim backdrop (captures touches while open; tap to close).
    UIView *backdrop = [[UIView alloc] initWithFrame:bounds];
    backdrop.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    backdrop.hidden = YES;
    [backdrop addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closePanel)]];
    [root addSubview:backdrop];
    self.backdrop = backdrop;

    CGFloat cw = MIN(320.0, bounds.size.width - 40.0);
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cw, 300)];
    card.center = CGPointMake(bounds.size.width / 2.0, bounds.size.height * 0.4);
    card.backgroundColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:0.98];
    card.layer.cornerRadius = 16;
    [backdrop addSubview:card];
    self.card = card;

    CGFloat pad = 16, y = 16, iw = cw - pad * 2;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, iw, 24)];
    title.text = @"OpenVCam 悬浮控制";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:17];
    [card addSubview:title];
    y += 34;

    UILabel *urlLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, iw, 18)];
    urlLabel.text = @"拉流地址 (RTMP)";
    urlLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    urlLabel.font = [UIFont systemFontOfSize:12];
    [card addSubview:urlLabel];
    y += 22;

    UITextField *url = [[UITextField alloc] initWithFrame:CGRectMake(pad, y, iw, 36)];
    url.text = VCAM_PANEL_DEFAULT_RTMP;
    url.textColor = UIColor.whiteColor;
    url.font = [UIFont systemFontOfSize:13];
    url.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    url.borderStyle = UITextBorderStyleRoundedRect;
    url.keyboardType = UIKeyboardTypeURL;
    url.autocorrectionType = UITextAutocorrectionTypeNo;
    url.autocapitalizationType = UITextAutocapitalizationTypeNone;
    url.clearButtonMode = UITextFieldViewModeWhileEditing;
    url.returnKeyType = UIReturnKeyDone;
    url.delegate = self;
    [card addSubview:url];
    self.urlField = url;
    y += 46;

    self.videoSwitch = [self addRowIn:card y:&y label:@"替换视频"];
    self.audioSwitch = [self addRowIn:card y:&y label:@"替换音频"];
    y += 4;

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, iw, 16)];
    status.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    status.font = [UIFont systemFontOfSize:11];
    status.textAlignment = NSTextAlignmentCenter;
    [card addSubview:status];
    self.statusLabel = status;
    y += 22;

    CGFloat bw = (iw - 10) / 2.0;
    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    save.frame = CGRectMake(pad, y, bw, 40);
    [save setTitle:@"保存" forState:UIControlStateNormal];
    [save setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    save.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    save.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    save.layer.cornerRadius = 10;
    [save addTarget:self action:@selector(onSave) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:save];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(pad + bw + 10, y, bw, 40);
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:16];
    close.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    close.layer.cornerRadius = 10;
    [close addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];
    y += 52;

    CGRect cf = card.frame; cf.size.height = y; card.frame = cf;
    card.center = CGPointMake(bounds.size.width / 2.0, bounds.size.height * 0.4);
}

// One "<label>  [switch]" row; advances *y and returns the switch.
- (UISwitch *)addRowIn:(UIView *)card y:(CGFloat *)yp label:(NSString *)text {
    CGFloat pad = 16, iw = card.bounds.size.width - pad * 2, y = *yp;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, iw - 60, 32)];
    l.text = text;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:15];
    [card addSubview:l];
    UISwitch *sw = [[UISwitch alloc] init];
    sw.onTintColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    CGRect sf = sw.frame;
    sw.frame = CGRectMake(pad + iw - sf.size.width, y + (32 - sf.size.height) / 2.0, sf.size.width, sf.size.height);
    [card addSubview:sw];
    *yp = y + 40;
    return sw;
}

#pragma mark - Gestures

- (void)onTap {
    if (self.open) [self closePanel]; else [self openPanel];
}

- (void)onPan:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:self.window];
    CGPoint c = self.fab.center;
    c.x += t.x; c.y += t.y;
    CGFloat r = self.fab.bounds.size.width / 2.0;
    CGRect b = self.window.bounds;
    c.x = MAX(r + 4, MIN(b.size.width - r - 4, c.x));
    c.y = MAX(r + 30, MIN(b.size.height - r - 30, c.y));
    self.fab.center = c;
    [pan setTranslation:CGPointZero inView:self.window];
}

#pragma mark - Open / close

- (void)openPanel {
    [self loadCurrentValues];
    self.statusLabel.text = @"";
    self.backdrop.hidden = NO;
    self.fab.hidden = YES;
    self.open = YES;
    [self.window makeKeyAndVisible];   // needed so the URL keyboard can appear
}

- (void)closePanel {
    [self.urlField resignFirstResponder];
    self.backdrop.hidden = YES;
    self.fab.hidden = NO;
    self.open = NO;
    [self.window resignKeyWindow];     // hand key back so the app/home screen behaves normally
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

// Populate the card from the current persisted config (file) + live notify state.
- (void)loadCurrentValues {
    NSDictionary *plist = nil;
    for (NSString *p in VCamPanelWritePaths()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) { plist = d; break; }
    }
    NSString *url = plist[@"rtmp"] ?: plist[@"Rtmp"] ?: plist[@"link"];
    self.urlField.text = (url.length > 0) ? url : VCAM_PANEL_DEFAULT_RTMP;

    BOOL video = YES, audio = YES;
    id v = plist[@"replaceVideo"] ?: plist[@"ReplaceVideo"];
    id a = plist[@"replaceAudio"] ?: plist[@"ReplaceAudio"];
    if ([v respondsToSelector:@selector(boolValue)]) video = [v boolValue];
    if ([a respondsToSelector:@selector(boolValue)]) audio = [a boolValue];
    BOOL e, sv, sa;                              // live notify state wins if published this boot
    if (VCamControlReadState(&e, &sv, &sa)) { video = sv; audio = sa; }
    self.videoSwitch.on = video;
    self.audioSwitch.on = audio;
}

#pragma mark - Save

- (void)onSave {
    NSString *url = [self.urlField.text stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (url.length == 0) url = VCAM_PANEL_DEFAULT_RTMP;
    BOOL video = self.videoSwitch.on;
    BOOL audio = self.audioSwitch.on;

    NSDictionary *cfg = @{ @"enabled": @YES,
                           @"rtmp": url,
                           @"replaceVideo": @(video),
                           @"replaceAudio": @(audio) };

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL anyWritten = NO, mediaWritten = NO;
    for (NSString *p in VCamPanelWritePaths()) {
        @try {
            [fm createDirectoryAtPath:[p stringByDeletingLastPathComponent]
          withIntermediateDirectories:YES attributes:nil error:nil];
            if ([cfg writeToFile:p atomically:YES] &&
                [NSDictionary dictionaryWithContentsOfFile:p] != nil) {   // verify readback
                anyWritten = YES;
                if (VCamPathReachesMediaserverd(p)) mediaWritten = YES;
            }
        } @catch (__unused NSException *e) { /* path not writable in this sandbox */ }
    }

    // Always publish the toggles on the notify bus — instant, and the only channel that
    // reaches TikTok. This makes the switches work even if every file write was blocked.
    VCamControlPublish(YES, video, audio);
    VCamLog(@"panel: saved url=%@ video=%d audio=%d fileWritten=%d mediaWritten=%d",
            url, video, audio, anyWritten, mediaWritten);

    if (mediaWritten)      self.statusLabel.text = @"✓ 已保存并热更新（视频/音频/地址）";
    else if (anyWritten)   self.statusLabel.text = @"✓ 开关已更新；地址写入受限";
    else                   self.statusLabel.text = @"✓ 开关已更新（通知）；文件不可写";
    self.statusLabel.textColor = [UIColor colorWithRed:0.3 green:0.85 blue:0.4 alpha:1.0];
}

@end

#pragma mark - Constructor (SpringBoard only)

%ctor {
    @autoreleasepool {
        @try {
            NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"";
            NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
            BOOL isSpringBoard = [proc isEqualToString:@"SpringBoard"] ||
                                 [bundle isEqualToString:@"com.apple.springboard"];
            if (!isSpringBoard) return;
            if ([[NSFileManager defaultManager] fileExistsAtPath:VCAM_PANEL_DISABLE_FILE]) {
                VCamLog(@"panel: disabled by %@", VCAM_PANEL_DISABLE_FILE);
                return;
            }
            // Build after SpringBoard is up. installWhenReady itself retries until a
            // foreground scene exists, so this only kicks it off.
            dispatch_async(dispatch_get_main_queue(), ^{
                if (UIApplication.sharedApplication) {
                    [[VCamPanelController shared] installWhenReady];
                } else {
                    [[NSNotificationCenter defaultCenter]
                        addObserverForName:UIApplicationDidFinishLaunchingNotification
                                    object:nil queue:[NSOperationQueue mainQueue]
                                usingBlock:^(NSNotification *n) {
                        (void)n; [[VCamPanelController shared] installWhenReady];
                    }];
                }
            });
        } @catch (NSException *e) {
            NSLog(@"[OpenVCam] panel ctor exception %@", e);
        }
    }
}

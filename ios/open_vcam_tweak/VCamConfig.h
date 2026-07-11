#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads OpenVCam configuration from /var/mobile/vc.plist (shared with the
/// closed vcamera model and the launcher's STEP 9d-2 seeding) and the
/// /var/mobile/vc.disabled kill-switch file.
///
/// The config object is polled on a background timer; all properties are
/// safe to read from any thread (backed by atomic copies).
@interface VCamConfig : NSObject

+ (instancetype)shared;

/// Master enable. NO when vc.plist Enabled=false OR /var/mobile/vc.disabled exists.
/// When NO the whole tweak must behave as a pure pass-through.
@property (atomic, readonly) BOOL enabled;

/// RTMP pull URL. Falls back to rtmp://127.10.10.10:1935/live/srs when the
/// vc.plist `rtmp` key is empty (mirrors vcam-smart-rtmp-fallback).
@property (atomic, copy, readonly) NSString *rtmpURL;

/// Force an immediate reload (also happens automatically on a 1.5s timer).
- (void)reloadNow;

@end

NS_ASSUME_NONNULL_END

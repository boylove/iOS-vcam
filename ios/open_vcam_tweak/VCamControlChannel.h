#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

// ---------------------------------------------------------------------------
// OpenVCam control channel — a cross-sandbox settings bus built on Darwin
// notifications (notify(3)).
//
// WHY THIS EXISTS. The floating panel lives in SpringBoard, but the settings it
// changes must reach TWO very differently-sandboxed consumers:
//   * mediaserverd — replaces video for every app + the stock Camera's mic. It
//     can read /var/mobile/Media/vc.plist (its sandbox allows the Media store),
//     so its RTMP URL + toggles can travel by FILE.
//   * TikTok (and other capture apps) — replace the mic IN-PROCESS. Their
//     third-party sandbox CANNOT read /var/mobile/Media, so a file cannot carry
//     a toggle to them at all.
// A Darwin notification is not filesystem-scoped: any process may post/observe a
// self-namespaced name and read its 64-bit state, crossing every sandbox. So the
// on/off TOGGLES ride this bus (instant, and TikTok-reachable); the RTMP URL
// STRING (which a 64-bit word can't hold) stays in the file, read by mediaserverd.
//
// The 64-bit state carries a VALID bit so a consumer can tell "the panel has
// published at least once this boot" (authoritative toggles) from "nothing
// published yet" (fall back to the file / compiled defaults). notify state is
// runtime-only (cleared on reboot); the file is the persistent store.
// ---------------------------------------------------------------------------

#define VCAM_NOTIFY_NAME "com.iosvcam.opencam.settings"

// 64-bit notify state bit layout.
#define VCAM_STATE_VALID    (1ULL << 0)   // panel has published at least once
#define VCAM_STATE_ENABLED  (1ULL << 1)   // master enable
#define VCAM_STATE_VIDEO    (1ULL << 2)   // replace video
#define VCAM_STATE_AUDIO    (1ULL << 3)   // replace audio

#ifdef __cplusplus
extern "C" {
#endif

/// Reader side. Fills the out params from the published notify state and returns
/// YES iff a valid state exists (panel published this boot). When it returns NO,
/// the caller keeps its file/compiled values. Any out pointer may be NULL.
BOOL VCamControlReadState(BOOL *enabled, BOOL *video, BOOL *audio);

/// Publisher side (SpringBoard panel). Encodes the toggles into the 64-bit state
/// (VALID set) and posts the notification so observers re-read immediately.
void VCamControlPublish(BOOL enabled, BOOL video, BOOL audio);

/// Reader side. Invoke `onChange` on `queue` (main queue if NULL) whenever the
/// state is republished. Register once per process; the block reads the fresh
/// values with VCamControlReadState.
void VCamControlObserve(dispatch_queue_t queue, dispatch_block_t onChange);

#ifdef __cplusplus
}
#endif

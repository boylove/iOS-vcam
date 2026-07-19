#import "VCamControlChannel.h"
#import <notify.h>

// One process-wide "check" token used for notify_get_state / notify_set_state.
// notifyd stores the 64-bit state keyed by NAME (shared across processes), so a
// single token per process is enough for both reading and writing it. Observer
// callbacks get their own dispatch tokens (VCamControlObserve).
static int gToken = -1;

static int VCamControlToken(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int t = -1;
        uint32_t st = notify_register_check(VCAM_NOTIFY_NAME, &t);
        gToken = (st == NOTIFY_STATUS_OK) ? t : -1;
    });
    return gToken;
}

BOOL VCamControlReadState(BOOL *enabled, BOOL *video, BOOL *audio, BOOL *zoomFollow) {
    int t = VCamControlToken();
    if (t < 0) return NO;
    uint64_t s = 0;
    if (notify_get_state(t, &s) != NOTIFY_STATUS_OK) return NO;
    if (!(s & VCAM_STATE_VALID)) return NO;            // nothing published this boot
    if (enabled)    *enabled    = (s & VCAM_STATE_ENABLED) ? YES : NO;
    if (video)      *video      = (s & VCAM_STATE_VIDEO)   ? YES : NO;
    if (audio)      *audio      = (s & VCAM_STATE_AUDIO)   ? YES : NO;
    if (zoomFollow) *zoomFollow = (s & VCAM_STATE_ZOOM)    ? YES : NO;
    return YES;
}

void VCamControlPublish(BOOL enabled, BOOL video, BOOL audio, BOOL zoomFollow) {
    int t = VCamControlToken();
    if (t < 0) return;
    uint64_t s = VCAM_STATE_VALID
               | (enabled    ? VCAM_STATE_ENABLED : 0)
               | (video      ? VCAM_STATE_VIDEO   : 0)
               | (audio      ? VCAM_STATE_AUDIO   : 0)
               | (zoomFollow ? VCAM_STATE_ZOOM    : 0);
    notify_set_state(t, s);
    notify_post(VCAM_NOTIFY_NAME);   // wake observers so they re-read immediately
}

void VCamControlObserve(dispatch_queue_t queue, dispatch_block_t onChange) {
    if (!onChange) return;
    int t = -1;
    notify_register_dispatch(VCAM_NOTIFY_NAME, &t,
                             queue ?: dispatch_get_main_queue(),
                             ^(int token) { (void)token; onChange(); });
}

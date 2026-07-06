/*
 * vcam_rtmp.h - Minimal self-contained RTMP *play* (pull) client.
 *
 * Purpose-built for OpenVCam: connects to an RTMP server, issues
 * connect/createStream/play, and delivers audio (type 8) / video (type 9)
 * message payloads to a callback. Plain rtmp:// only (no TLS/rtmps).
 *
 * This is intentionally small and hackable rather than a full librtmp; the
 * whole point of OpenVCam is that you can edit this.
 */
#ifndef VCAM_RTMP_H
#define VCAM_RTMP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct vcam_rtmp vcam_rtmp;

/*
 * Called for each complete media message.
 *   msg_type      : 8 = audio, 9 = video
 *   timestamp_ms  : message timestamp in milliseconds
 *   data/len      : FLV tag body (for video: [frametype|codecid][pkttype][cts:3][body])
 * The buffer is owned by the client and only valid for the duration of the call.
 */
typedef void (*vcam_rtmp_media_cb)(void *ctx, uint8_t msg_type,
                                   uint32_t timestamp_ms,
                                   const uint8_t *data, size_t len);

/* Optional logging hook (may be NULL). */
typedef void (*vcam_rtmp_log_cb)(void *ctx, const char *message);

/* Create a client for `url` (rtmp://host[:port]/app/playpath). Copies url. */
vcam_rtmp *vcam_rtmp_create(const char *url,
                            vcam_rtmp_log_cb log_cb, void *log_ctx);

/*
 * Connect, play, and run the read loop, invoking `cb` for each media message.
 * Blocks until the connection closes, an error occurs, or *stop_flag != 0.
 * Returns 0 on a stop-requested/clean exit, negative on connect/protocol error.
 */
int vcam_rtmp_run(vcam_rtmp *r, vcam_rtmp_media_cb cb, void *ctx,
                  volatile int *stop_flag);

void vcam_rtmp_destroy(vcam_rtmp *r);

#ifdef __cplusplus
}
#endif

#endif /* VCAM_RTMP_H */

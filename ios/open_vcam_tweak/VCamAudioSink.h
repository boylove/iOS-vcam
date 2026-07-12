#pragma once
#include <stdint.h>

// Bridge from the RTMP audio decoder (VCamRTMPSource, producer thread) to the mediaserverd
// microphone-replacement FIFO in VCamAudioMS.x. Defined there; declared here so the ObjC++
// RTMP source can push decoded OBS audio into the same shared FIFO the AudioUnitRender hook
// (broadcast model) consumes. See VCamAudioMS.x for the full real-time-safety model.

#ifdef __cplusplus
extern "C" {
#endif

// Push `srcFrames` of interleaved int16 PCM at (srcRate, srcCh) into the FIFO. Off-RT only
// (call from the single RTMP reader thread). Stores at the source format; the consumer requires
// the render unit's rate to equal srcRate (no RT resampling) and channel-maps mono<->stereo at
// pop. srcCh must be 1 or 2. `ptsMs` is this frame's RTMP presentation timestamp (ms), used for
// A/V telemetry only (video is real-time after the fps fix, so audio just plays through). Pass 0.
void IVCAMMediaActivePushPCM(const int16_t *pcm, uint32_t srcFrames,
                             uint32_t srcRate, uint32_t srcCh, int64_t ptsMs);

// Publish the currently-displayed video frame's RTMP PTS (ms), from the H264 decoder's output
// callback. Telemetry only in the broadcast model (logged as the A/V lead); it no longer drives
// a buffer target. Kept so the H264 decoder's call site and the shared-sink ABI are unchanged.
void IVCAMSetVideoPTS(int64_t ptsMs);

// Signal OBS streaming state (1 on RTMP connect, 0 on disconnect). While set, a mic-input render
// that underruns MUTES rather than leaking the real mic — but only if OBS audio was produced
// recently (a live stream's momentary gap); a video-only stream or the pre-first-frame startup
// falls open to the real mic. When clear, mic inputs always fall open to the real mic.
void IVCAMSetOBSStreaming(int on);

#ifdef __cplusplus
}
#endif

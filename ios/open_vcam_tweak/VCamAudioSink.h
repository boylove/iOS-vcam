#pragma once
#include <stdint.h>

// Bridge from the RTMP audio decoder (VCamRTMPSource, producer thread) to the mediaserverd
// microphone-replacement ring in VCamAudioMS.x. Defined there; declared here so the ObjC++
// RTMP source can push decoded OBS audio into the same lock-free ring the AudioUnitRender hook
// consumes. See VCamAudioMS.x for the full real-time-safety model.

#ifdef __cplusplus
extern "C" {
#endif

// Push `srcFrames` of interleaved int16 PCM at (srcRate, srcCh) into the ring. Off-RT only
// (call from the single RTMP reader thread). No-op until a consumer AudioUnit has latched its
// target format; adapts (channel-map + resample) to that format internally. srcCh must be 1 or 2.
// `ptsMs` is this audio frame's RTMP presentation timestamp (ms); it drives dynamic A/V sync
// (the newest written sample's PTS vs the displayed video PTS). Pass 0 if unknown.
void IVCAMMediaActivePushPCM(const int16_t *pcm, uint32_t srcFrames,
                             uint32_t srcRate, uint32_t srcCh, int64_t ptsMs);

// Publish the currently-displayed video frame's RTMP PTS (ms), from the H264 decoder's output
// callback. The audio consumer buffers exactly (newest-audio-PTS - this) so the audio it plays
// lands on the shown video's PTS — dynamic, self-correcting A/V sync (no fixed delay).
void IVCAMSetVideoPTS(int64_t ptsMs);

// Signal OBS streaming state (1 on RTMP connect, 0 on disconnect). While set, mic-input renders
// are muted rather than leaking the real mic when OBS audio can't yet be supplied; when clear,
// mic inputs fall open to the real mic. Lets the audio hook silence the startup window.
void IVCAMSetOBSStreaming(int on);

#ifdef __cplusplus
}
#endif

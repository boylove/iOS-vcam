// ---------------------------------------------------------------------------
// OpenVCam — mediaserverd OBS-audio FIFO (0.6.45).
//
// The mic replacement in mediaserverd is now done at the SAME BW-graph emit hook
// as the video overwrite (Tweak.xm VCamEmit -> BWNodeOutput -emitSampleBuffer:),
// NOT via an AudioUnitRender hook. Device-proven (2026-07-12): the AudioUnitRender
// hook sits on the hot audio IO path of the A/V-synced capture graph and (a) drops
// video fps 29.98 -> 24 and (b) crashes repeat-record with a SIGTRAP (HAL overload
// on the 2nd capture). The closed original has no audio hook and repeat-records at
// 29.98. The BW emit hook is OFF the hot IO path (video-only is clean there), and a
// probe (0.6.44) confirmed AUDIO sample buffers flow through that same emit hook as
// int16 interleaved (typically 44100 stereo, matching the OBS AAC) — so we overwrite
// the audio PCM IN PLACE there, exactly like the video image buffer.
//
// This file is now just the FIFO: the AAC decoder pushes decoded OBS PCM here
// (IVCAMMediaActivePushPCM, via the per-process gVCamPCMSink), and the emit hook
// pops matching PCM (IVCAMAudioPopForEmit). No AudioUnitRender hook, no %ctor, no
// real-time render path. Fail-open: no OBS audio / format mismatch -> the real mic.
// ---------------------------------------------------------------------------
#import <Foundation/Foundation.h>
#import <os/lock.h>
#import <stdlib.h>
#import <string.h>
#import <stdatomic.h>
#import <mach/mach_time.h>

#import "VCamAudioSink.h"

// Keep only the freshest ~this many ms of OBS audio (drop oldest); bounds A/V latency and, since
// it is a CAP not an additive delay, it does not drift over a long stream.
#define IVCAM_AUDIO_CAP_MS 250u
#define IVCAM_AUDIO_MAX_BYTES (48000u * 2u * 2u)   // 1 s @ 48 kHz stereo int16, hard ceiling

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static uint8_t  *gBuf = NULL;   // heap FIFO: int16 interleaved at the source format
static size_t    gLen = 0;      // valid bytes
static size_t    gCap = 0;      // allocated bytes
static uint32_t  gRate = 0;     // source format (published on first push)
static uint32_t  gCh = 0;
static volatile int32_t gOBS = 0;

// stats (read by Tweak.xm's health line via the accessors below)
static volatile uint64_t gPushed = 0;
static volatile uint64_t gPopHit = 0;
static volatile uint64_t gPopMiss = 0;

// Displayed-video PTS bus for dynamic A/V sync. The H264 decoder publishes the newest decoded OBS
// frame's RTMP PTS here (VCamH264Decoder output callback) together with the mach time it landed; the
// mediaserverd mic-injection ring (VCamAudioProbe.x) reads it to lock the audio it plays onto the video
// shown NOW, instead of a fixed guessed latency. Two plain atomics (ms + host ticks); a torn read is at
// most one frame stale and self-corrects on the next render.
static _Atomic int64_t  gVCamVideoPtsMs   = 0;
static _Atomic uint64_t gVCamVideoPtsHost = 0;
void IVCAMSetVideoPTS(int64_t ptsMs) {
    atomic_store_explicit(&gVCamVideoPtsHost, mach_absolute_time(), memory_order_relaxed);
    atomic_store_explicit(&gVCamVideoPtsMs,   ptsMs, memory_order_release);
}
int64_t  IVCAMVideoPtsMs(void)   { return atomic_load_explicit(&gVCamVideoPtsMs,   memory_order_acquire); }
uint64_t IVCAMVideoPtsHost(void) { return atomic_load_explicit(&gVCamVideoPtsHost, memory_order_relaxed); }

// Camera-capture-active heartbeat. The video emit hook (Tweak.xm VCamEmit) stamps this every time the
// capture graph emits a frame; the mediaserverd mic injection (VCamAudioProbe.x) gates on it so it ONLY
// overwrites the mic WHILE A CAPTURE IS RUNNING — not during Photos/music playback, whose OUTPUT audio
// also flows through mono AudioUnitProcess units. The broad 0.6.58 inject clobbered those too, bleeding
// OBS/tone over all device playback (that's why Photos playback carried the OBS sound / the tone).
static _Atomic uint64_t gVCamCamHost = 0;
void IVCAMNoteCameraActive(void) {
    atomic_store_explicit(&gVCamCamHost, mach_absolute_time(), memory_order_relaxed);
}
int IVCAMCameraActive(void) {
    uint64_t last = atomic_load_explicit(&gVCamCamHost, memory_order_relaxed);
    if (!last) return 0;
    static _Atomic double toMs = 0.0;
    double m = atomic_load_explicit(&toMs, memory_order_relaxed);
    if (m == 0.0) { mach_timebase_info_data_t tb; mach_timebase_info(&tb);
                    m = (double)tb.numer / (double)tb.denom / 1.0e6;
                    atomic_store_explicit(&toMs, m, memory_order_relaxed); }
    uint64_t now = mach_absolute_time();
    return (now > last) && ((double)(now - last) * m < 700.0);   // active if a frame emitted within 700 ms
}
void IVCAMSetOBSStreaming(int on) { __atomic_store_n(&gOBS, on ? 1 : 0, __ATOMIC_RELEASE); }
int  IVCAMAudioOBSStreaming(void) { return __atomic_load_n(&gOBS, __ATOMIC_ACQUIRE); }

void IVCAMAudioStats(uint64_t *pushed, uint64_t *hit, uint64_t *miss, uint32_t *rate, uint32_t *ch, uint32_t *fillMs) {
    os_unfair_lock_lock(&gLock);
    uint32_t r = gRate, c = gCh; size_t len = gLen;
    os_unfair_lock_unlock(&gLock);
    if (pushed) *pushed = __atomic_load_n(&gPushed, __ATOMIC_RELAXED);
    if (hit)    *hit = __atomic_load_n(&gPopHit, __ATOMIC_RELAXED);
    if (miss)   *miss = __atomic_load_n(&gPopMiss, __ATOMIC_RELAXED);
    if (rate)   *rate = r;
    if (ch)     *ch = c;
    if (fillMs) *fillMs = (r && c) ? (uint32_t)(len * 1000ull / ((uint64_t)r * c * 2u)) : 0;
}

// Producer: append decoded OBS PCM (interleaved int16 at (rate, ch)). Off-RT (RTMP/AAC thread).
void IVCAMMediaActivePushPCM(const int16_t *pcm, uint32_t frames, uint32_t rate, uint32_t ch, int64_t ptsMs) {
    (void)ptsMs;
    if (!pcm || frames == 0 || !(ch == 1 || ch == 2) || rate == 0 || rate > 192000) return;
    size_t bytes = (size_t)frames * ch * 2u;

    os_unfair_lock_lock(&gLock);
    if (gRate != rate || gCh != ch) { gLen = 0; gRate = rate; gCh = ch; }   // format change -> reset
    size_t capBytes = (size_t)rate * IVCAM_AUDIO_CAP_MS / 1000u * ch * 2u;
    if (capBytes > IVCAM_AUDIO_MAX_BYTES) capBytes = IVCAM_AUDIO_MAX_BYTES;
    if (gCap < capBytes + bytes) {
        size_t nc = capBytes + bytes;
        uint8_t *nb = (uint8_t *)realloc(gBuf, nc);
        if (!nb) { os_unfair_lock_unlock(&gLock); return; }
        gBuf = nb; gCap = nc;
    }
    if (gLen + bytes > capBytes) {                       // drop oldest to stay under the cap
        size_t drop = (gLen + bytes) - capBytes;
        if (drop > gLen) drop = gLen;
        if (gLen > drop) memmove(gBuf, gBuf + drop, gLen - drop);
        gLen -= drop;
    }
    memcpy(gBuf + gLen, pcm, bytes);
    gLen += bytes;
    os_unfair_lock_unlock(&gLock);
    __atomic_add_fetch(&gPushed, 1, __ATOMIC_RELAXED);
}

// Consumer (called from the BW emit hook, off the hot IO path): pop `frames` of PCM matching
// (rate, ch) into dst (int16 interleaved), overwriting it in place. Returns 1 if fully filled.
// Requires an exact format match with the buffered OBS audio (both are 44100/48000 stereo int16
// in practice); on mismatch or underrun returns 0 and the caller keeps the real mic.
int IVCAMAudioPopForEmit(int16_t *dst, uint32_t frames, uint32_t rate, uint32_t ch) {
    if (!dst || frames == 0 || !(ch == 1 || ch == 2) || rate == 0) return 0;
    size_t need = (size_t)frames * ch * 2u;
    os_unfair_lock_lock(&gLock);
    if (gRate != rate || gCh != ch || gLen < need) {
        os_unfair_lock_unlock(&gLock);
        __atomic_add_fetch(&gPopMiss, 1, __ATOMIC_RELAXED);
        return 0;
    }
    memcpy(dst, gBuf, need);
    if (gLen > need) memmove(gBuf, gBuf + need, gLen - need);
    gLen -= need;
    os_unfair_lock_unlock(&gLock);
    __atomic_add_fetch(&gPopHit, 1, __ATOMIC_RELAXED);
    return 1;
}

// ---------------------------------------------------------------------------
// OpenVCam — audio subsystem (GLOBAL, mediaserverd). BROADCAST model.
//
// Rewritten (0.6.39) from the single-latch/steal/leak-guard consumer to the
// simple broadcast model proven in ios/audio_bridge_safe_tweak: ANY microphone-
// input (bus 1) render pops directly from ONE shared PCM FIFO and fills its
// buffer with OBS audio. There is no "latched" consumer unit, no latch stealing,
// no priming water level, and no dynamic-PTS jitter target — those fought
// TikTok's multi-unit VoiceProcessingIO path (the latch landed on the wrong unit
// -> silence, and the steal churn crash-looped mediaserverd). Whichever unit is
// actually rendering the mic gets the audio; that is naturally multi-app because
// only one app records at a time.
//
// The producer is UNCHANGED in spirit: OBS audio is demuxed from the same RTMP
// stream the video path pulls (VCamRTMPSource msg_type 8 -> VCamAACDecoder ->
// IVCAMMediaActivePushPCM), decoded to interleaved int16 at the stream's native
// rate/channels, and appended to the FIFO. The consumer requires the render
// unit's sample rate to equal the stream's (no RT-thread resampling, like the
// safe tweak); it channel-maps (mono<->stereo) at pop time and handles int16 /
// float32, interleaved / non-interleaved outputs.
//
// FIFO: a fixed int16 ring guarded by one os_unfair_lock. The lock is held only
// for the ring memcpy (a few microseconds); os_unfair_lock donates priority so a
// producer append cannot priority-invert the render thread. This is strictly
// correct for the (rare) case of two apps rendering the mic concurrently, and
// avoids the safe tweak's per-render NSData alloc + O(n) front-erase.
//
// Fail-open everywhere: any error / no stream / rate mismatch / FIFO underrun
// falls back to the real microphone. The ONE exception is the mic-leak guard:
// while OBS audio is actively flowing (recently produced) a momentary underrun
// MUTES rather than leaking the real mic into the recording — but a stream with
// NO audio track (video-only OBS), or the pre-first-frame startup window, falls
// open to the real mic so ordinary recording keeps working.
//
// Recovery if anything wedges: remove the package + `killall mediaserverd`.
// ---------------------------------------------------------------------------
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <substrate.h>
#import <dispatch/dispatch.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <stdarg.h>
#import <stdint.h>
#import <string.h>
#import <syslog.h>
#import <unistd.h>

#define IVCAM_AUDIO_PREFS      @"/var/mobile/Library/Preferences/com.iosvcam.audiobridge.media-active.plist"
#define IVCAM_AUDIO_DISABLE_FLAG @"/var/mobile/Library/Preferences/com.iosvcam.audiobridge.media-active.disabled"
#define IVCAM_AUDIO_PREFS_DOMAIN CFSTR("com.iosvcam.audiobridge.media-active")
#define IVCAM_AUDIO_LOG        @"iOSVCAMAudioBridgeMediaActive.log"
#define IVCAM_AUDIO_TARGET_BUNDLE  @"com.apple.mediaserverd"
#define IVCAM_AUDIO_TARGET_PROCESS @"mediaserverd"

// FIFO ring holds source-format interleaved int16. 1<<17 = 131072 samples =
// ~2.7 s mono / ~1.37 s stereo @ 48 kHz, well above the FIFO cap below.
#define IVCAM_RING_SAMPLES (1u << 17)
#define IVCAM_RING_MASK    (IVCAM_RING_SAMPLES - 1u)

// Largest render we service on the stack scratch; larger renders fall open. 8192
// frames * 2 ch = 32 KiB of int16 on the render thread's stack (fine; common
// renders are 1024). Bounds the consumer's stack copy.
#define IVCAM_MAX_RENDER_FRAMES 8192u

// FIFO high-water cap: keep at most ~1 s of the FRESHEST audio. Only trips when
// the consumer stalls (e.g. between recordings) while the producer keeps feeding;
// dropping the oldest bounds the stall-resume latency. In steady state the
// consumer drains each render so the FIFO sits near empty and this never fires.
#define IVCAM_FIFO_CAP_MS 1000u

// Mic-leak guard window: an underrun is treated as a momentary gap in a LIVE
// audio stream (-> mute, no real-mic leak) only if OBS audio was produced within
// this window. Older/never -> the stream has no audio (or hasn't started), so
// fall open to the real mic.
#define IVCAM_RECENT_AUDIO_US 500000ull

// Format-probe throttle. AudioUnitGetProperty is NOT cheap on the render thread;
// calling it on EVERY bus-1 render across mediaserverd's many mic units blows the
// HAL RT budget (ClientHALIODurationExceededBudget -> mediaserverd crash-loop —
// the 0.6.36 regression). So probe the render unit's format at most once per this
// interval, cache it (packed, lock-free), and reuse the cache on every render.
// This is the ONE piece the safe tweak didn't need (it runs in-process, not
// mediaserverd); consumption stays broadcast — the cache is format only, never a
// consumer identity, so any bus-1 unit still fills from it.
#define IVCAM_FMT_PROBE_US 200000ull

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------
static int16_t   gRing[IVCAM_RING_SAMPLES];  // source-format interleaved int16
static uint32_t  gReadIdx = 0;               // guarded by gAudioLock
static uint32_t  gWriteIdx = 0;              // guarded by gAudioLock
static os_unfair_lock gAudioLock = OS_UNFAIR_LOCK_INIT;

// FIFO source format, published by the producer (0 until the first push). Read
// under gAudioLock by the consumer.
static uint32_t  gFifoRate = 0;
static uint32_t  gFifoChannels = 0;

// Cached render-unit format, packed into one word so it reads/writes atomically
// (no torn read, no valid flag): bits 0-17 rate, 18-19 channels, 20 isFloat,
// 21 nonInterleaved; 0 = not yet probed. Refreshed by a rate-limited probe on the
// render thread (gLastProbeUs), read lock-free on every render.
static volatile uint32_t gFmtPacked = 0;
static volatile uint64_t gLastProbeUs = 0;

static inline uint32_t IVCAMPackFmt(uint32_t rate, uint32_t ch, uint32_t isFloat, uint32_t ni) {
    return (rate & 0x3FFFFu) | ((ch & 0x3u) << 18) | ((isFloat & 1u) << 20) | ((ni & 1u) << 21);
}

static volatile int32_t  gEnabled = 1;           // runtime gate (prefs / disable flag)
static volatile int32_t  gOBSStreaming = 0;      // set by RTMP connect/disconnect
static volatile uint64_t gLastProducedUs = 0;    // monotonic us of the last PushPCM

// Telemetry only (no longer drives sync — video is real-time after the fps fix).
static volatile int64_t  gVideoPTSms = 0;
static volatile int64_t  gAudioWritePTSms = 0;

// Stat counters (RELAXED).
static volatile uint64_t gRenderCalls = 0;
static volatile uint64_t gReplaced = 0;
static volatile uint64_t gUnderruns = 0;
static volatile uint64_t gMuted = 0;
static volatile uint64_t gOverflowDrops = 0;
static volatile uint64_t gUnsupported = 0;

static uint32_t gTbNumer = 1;   // mach timebase, cached at ctor
static uint32_t gTbDenom = 1;

static OSStatus (*gOriginalAudioUnitRender)(AudioUnit inUnit,
                                            AudioUnitRenderActionFlags *ioActionFlags,
                                            const AudioTimeStamp *inTimeStamp,
                                            UInt32 inOutputBusNumber,
                                            UInt32 inNumberFrames,
                                            AudioBufferList *ioData) = NULL;

// Monotonic microseconds (mach_absolute_time is commpage-backed, RT-safe).
static inline uint64_t IVCAMNowUs(void) {
    return (mach_absolute_time() * (uint64_t)gTbNumer / (uint64_t)gTbDenom) / 1000ull;
}

// ---------------------------------------------------------------------------
// Logging (off-render-thread only)
// ---------------------------------------------------------------------------
static NSArray<NSString *> *IVCAMAudioLogPaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    [paths addObject:[@"/var/mobile/Library/Logs" stringByAppendingPathComponent:IVCAM_AUDIO_LOG]];
    [paths addObject:[@"/var/tmp" stringByAppendingPathComponent:IVCAM_AUDIO_LOG]];
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length > 0) [paths addObject:[tmp stringByAppendingPathComponent:IVCAM_AUDIO_LOG]];
    [paths addObject:[@"/tmp" stringByAppendingPathComponent:IVCAM_AUDIO_LOG]];
    return paths;
}

static BOOL IVCAMAudioAppendLog(NSString *path, NSData *data) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if (attrs && [attrs[NSFileSize] unsignedLongLongValue] > 131072) {
        [fm removeItemAtPath:path error:nil];
    }
    if (![fm fileExistsAtPath:path]) return [data writeToFile:path atomically:NO];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return NO;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
        return YES;
    } @catch (NSException *e) {
        @try { [handle closeFile]; } @catch (NSException *e2) { }
        return NO;
    }
}

// Off-render-thread only (ctor / producer / background timer).
static void IVCAMAudioLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *path in IVCAMAudioLogPaths()) {
        if (IVCAMAudioAppendLog(path, data)) break;
    }
    const char *utf8 = [message UTF8String];
    if (utf8) syslog(LOG_NOTICE, "[iOSVCAMAudioBridgeMediaActive] %s", utf8);
    NSLog(@"[iOSVCAMAudioBridgeMediaActive] %@", message);
}

// ---------------------------------------------------------------------------
// Preferences (off-render-thread only) — just the runtime enable/disable gate.
// The old host/port/rate/channels/jitter knobs are gone with the :1936 socket
// producer (audio now always comes from the shared RTMP stream).
// ---------------------------------------------------------------------------
static BOOL IVCAMAudioPathExists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static id IVCAMAudioCopyPref(NSString *key) {
    CFPreferencesAppSynchronize(IVCAM_AUDIO_PREFS_DOMAIN);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, IVCAM_AUDIO_PREFS_DOMAIN));
}

static BOOL IVCAMAudioReloadPrefs(BOOL verbose) {
    id disabledPref = IVCAMAudioCopyPref(@"Disabled");
    BOOL disabled = ([disabledPref respondsToSelector:@selector(boolValue)] && [disabledPref boolValue]) ||
                    IVCAMAudioPathExists(IVCAM_AUDIO_DISABLE_FLAG);
    if (disabled) {
        __atomic_store_n(&gEnabled, 0, __ATOMIC_RELEASE);
        if (verbose) IVCAMAudioLog(@"AUDIO_PREFS disabled by flag");
        return NO;
    }
    NSDictionary *filePrefs = [NSDictionary dictionaryWithContentsOfFile:IVCAM_AUDIO_PREFS];
    id enabledValue = IVCAMAudioCopyPref(@"Enabled") ?: filePrefs[@"Enabled"];
    BOOL hasEnabled = [enabledValue respondsToSelector:@selector(boolValue)];
    BOOL enabled = hasEnabled ? [enabledValue boolValue] : YES;
    __atomic_store_n(&gEnabled, enabled ? 1 : 0, __ATOMIC_RELEASE);
    if (verbose) IVCAMAudioLog(@"AUDIO_PREFS enabled=%d source=%@", enabled, hasEnabled ? @"prefs" : @"default");
    return enabled;
}

// ---------------------------------------------------------------------------
// Producer — append decoded OBS PCM to the FIFO. Off-RT only (RTMP/AAC thread).
// Keeps the shared-sink symbols the rest of the tweak links against.
// ---------------------------------------------------------------------------
void IVCAMMediaActivePushPCM(const int16_t *pcm, uint32_t srcFrames,
                             uint32_t srcRate, uint32_t srcCh, int64_t ptsMs) {
    if (!pcm || srcFrames == 0 || !(srcCh == 1 || srcCh == 2)) return;
    if (srcRate == 0 || srcRate > 192000) return;
    if (!__atomic_load_n(&gEnabled, __ATOMIC_ACQUIRE)) return;

    // Publish the newest sample's PTS (start + duration) for A/V telemetry.
    if (ptsMs > 0)
        __atomic_store_n(&gAudioWritePTSms, ptsMs + (int64_t)srcFrames * 1000 / (int64_t)srcRate, __ATOMIC_RELEASE);

    uint32_t n = srcFrames * srcCh;   // interleaved int16 samples
    if (n > IVCAM_RING_SAMPLES) return;   // absurd payload; ignore

    os_unfair_lock_lock(&gAudioLock);
    // Format change (or first push): reset the ring and republish the format.
    if (gFifoRate != srcRate || gFifoChannels != srcCh) {
        gReadIdx = gWriteIdx = 0;
        gFifoRate = srcRate;
        gFifoChannels = srcCh;
    }
    // Cap the FIFO to the freshest IVCAM_FIFO_CAP_MS: if appending would exceed it,
    // drop the oldest so latency stays bounded when the consumer is stalled.
    uint32_t capSamples = (uint32_t)((uint64_t)IVCAM_FIFO_CAP_MS * srcRate / 1000ull) * srcCh;
    if (capSamples > IVCAM_RING_SAMPLES) capSamples = IVCAM_RING_SAMPLES;
    uint32_t used = gWriteIdx - gReadIdx;
    if (used + n > capSamples) {
        uint32_t drop = (used + n) - capSamples;
        if (drop > used) drop = used;          // never advance read past write
        drop -= drop % srcCh;                  // whole frames
        gReadIdx += drop;
        __atomic_add_fetch(&gOverflowDrops, drop, __ATOMIC_RELAXED);
    }
    uint32_t pos = gWriteIdx & IVCAM_RING_MASK;
    uint32_t first = IVCAM_RING_SAMPLES - pos;
    if (first > n) first = n;
    memcpy(&gRing[pos], pcm, (size_t)first * sizeof(int16_t));
    if (n > first) memcpy(&gRing[0], pcm + first, (size_t)(n - first) * sizeof(int16_t));
    gWriteIdx += n;
    os_unfair_lock_unlock(&gAudioLock);

    __atomic_store_n(&gLastProducedUs, IVCAMNowUs(), __ATOMIC_RELEASE);
}

void IVCAMSetVideoPTS(int64_t ptsMs) { __atomic_store_n(&gVideoPTSms, ptsMs, __ATOMIC_RELEASE); }
void IVCAMSetOBSStreaming(int on) { __atomic_store_n(&gOBSStreaming, on ? 1 : 0, __ATOMIC_RELEASE); }

// ---------------------------------------------------------------------------
// Render hook (render thread; real-time)
// ---------------------------------------------------------------------------

// Map one source frame's channel `c` (0..targetCh-1) to an int16 sample.
static inline int16_t IVCAMMapSample(const int16_t *src, uint32_t i, uint32_t c,
                                     uint32_t srcCh, uint32_t targetCh) {
    if (srcCh == targetCh) return src[i * srcCh + c];
    if (srcCh == 1) return src[i];                                   // mono -> stereo (dup)
    return (int16_t)(((int32_t)src[i * 2] + (int32_t)src[i * 2 + 1]) / 2);  // stereo -> mono
}

// Zero every output buffer (silence the render). RT-safe.
static inline void IVCAMMuteRT(AudioBufferList *ioData) {
    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++)
        if (ioData->mBuffers[i].mData)
            memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
}

// Fill ioData with OBS audio popped from the FIFO. Returns YES if replaced, NO on
// any unsupported format / rate mismatch / underrun (caller then mutes or falls
// open). RT-safe: no ObjC, no alloc; one os_unfair_lock-guarded ring memcpy into a
// stack scratch then pure arithmetic. The only CoreAudio property call is the
// format probe, rate-limited to ~IVCAM_FMT_PROBE_US (never per render).
static BOOL IVCAMFillFromFifo(AudioUnit inUnit, UInt32 bus,
                              UInt32 inNumberFrames, AudioBufferList *ioData) {
    if (inNumberFrames == 0 || inNumberFrames > IVCAM_MAX_RENDER_FRAMES) return NO;

    // Render-unit format from the rate-limited cache, NOT a per-render
    // AudioUnitGetProperty (that overloads the HAL budget in mediaserverd). Probe
    // at most once per IVCAM_FMT_PROBE_US, publish the packed format, reuse it.
    uint64_t nowUs = IVCAMNowUs();
    uint32_t packed = __atomic_load_n(&gFmtPacked, __ATOMIC_ACQUIRE);
    uint64_t lastProbe = __atomic_load_n(&gLastProbeUs, __ATOMIC_RELAXED);
    if (packed == 0 || nowUs - lastProbe > IVCAM_FMT_PROBE_US) {
        // One prober at a time (CAS the timestamp); losers reuse the current cache.
        if (__atomic_compare_exchange_n(&gLastProbeUs, &lastProbe, nowUs, false,
                                        __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
            AudioStreamBasicDescription asbd;
            UInt32 size = sizeof(asbd);
            memset(&asbd, 0, sizeof(asbd));
            OSStatus fs = AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat,
                                               kAudioUnitScope_Output, bus, &asbd, &size);
            if (fs != noErr) {
                size = sizeof(asbd);
                fs = AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Input, bus, &asbd, &size);
            }
            if (fs == noErr) {
                BOOL pFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
                BOOL pInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
                BOOL pNI = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
                uint32_t pCh = asbd.mChannelsPerFrame;
                if (pCh == 0 && pNI) pCh = ioData->mNumberBuffers;
                if (asbd.mFormatID == kAudioFormatLinearPCM && (pCh == 1 || pCh == 2) &&
                    asbd.mSampleRate > 0.0 && asbd.mSampleRate <= 192000.0 &&
                    ((pFloat && asbd.mBitsPerChannel == 32) || (pInt && asbd.mBitsPerChannel == 16))) {
                    packed = IVCAMPackFmt((uint32_t)asbd.mSampleRate, pCh, pFloat ? 1 : 0, pNI ? 1 : 0);
                    __atomic_store_n(&gFmtPacked, packed, __ATOMIC_RELEASE);
                } else {
                    __atomic_add_fetch(&gUnsupported, 1, __ATOMIC_RELAXED);
                }
            }
        }
    }
    if (packed == 0) return NO;   // format not known yet -> caller mutes / falls open

    uint32_t fmtRate = packed & 0x3FFFFu;
    UInt32 targetCh = (packed >> 18) & 0x3u;
    BOOL isFloat = ((packed >> 20) & 1u) != 0;
    BOOL nonInterleaved = ((packed >> 21) & 1u) != 0;
    if (!(targetCh == 1 || targetCh == 2)) return NO;

    // Cross-check the actual buffer layout against the cached format (cheap, no HAL);
    // fall open if a unit's layout contradicts the cache (e.g. just after an app or
    // format switch, before the next probe refreshes it). Also guards consuming.
    if (nonInterleaved) {
        if (ioData->mNumberBuffers < targetCh) return NO;
        for (UInt32 ch = 0; ch < targetCh; ch++)
            if (!ioData->mBuffers[ch].mData) return NO;
    } else {
        if (ioData->mNumberBuffers < 1 || !ioData->mBuffers[0].mData) return NO;
    }

    // Pop inNumberFrames of source PCM under the lock (rate must match the FIFO).
    int16_t src[IVCAM_MAX_RENDER_FRAMES * 2];   // <=32 KiB stack, whole render only
    uint32_t srcCh;
    os_unfair_lock_lock(&gAudioLock);
    srcCh = gFifoChannels;
    if (gFifoRate == 0 || !(srcCh == 1 || srcCh == 2) || gFifoRate != fmtRate) {
        os_unfair_lock_unlock(&gAudioLock);
        return NO;                              // no stream yet / rate mismatch
    }
    uint32_t needSrc = inNumberFrames * srcCh;
    if (gWriteIdx - gReadIdx < needSrc) {
        os_unfair_lock_unlock(&gAudioLock);
        __atomic_add_fetch(&gUnderruns, 1, __ATOMIC_RELAXED);
        return NO;                              // underrun -> caller mutes / falls open
    }
    uint32_t pos = gReadIdx & IVCAM_RING_MASK;
    uint32_t first = IVCAM_RING_SAMPLES - pos;
    if (first > needSrc) first = needSrc;
    memcpy(src, &gRing[pos], (size_t)first * sizeof(int16_t));
    if (needSrc > first) memcpy(src + first, &gRing[0], (size_t)(needSrc - first) * sizeof(int16_t));
    gReadIdx += needSrc;
    os_unfair_lock_unlock(&gAudioLock);

    // Write scratch -> ioData with channel mapping (int16/float, interleaved/non).
    if (isFloat) {
        if (nonInterleaved) {
            for (UInt32 ch = 0; ch < targetCh; ch++) {
                float *out = (float *)ioData->mBuffers[ch].mData;
                UInt32 wf = ioData->mBuffers[ch].mDataByteSize / (UInt32)sizeof(float);
                if (wf > inNumberFrames) wf = inNumberFrames;
                for (UInt32 i = 0; i < wf; i++)
                    out[i] = (float)IVCAMMapSample(src, i, ch, srcCh, targetCh) / 32768.0f;
                ioData->mBuffers[ch].mDataByteSize = wf * (UInt32)sizeof(float);
            }
        } else {
            float *out = (float *)ioData->mBuffers[0].mData;
            UInt32 wf = ioData->mBuffers[0].mDataByteSize / ((UInt32)sizeof(float) * targetCh);
            if (wf > inNumberFrames) wf = inNumberFrames;
            for (UInt32 i = 0; i < wf; i++)
                for (UInt32 c = 0; c < targetCh; c++)
                    out[i * targetCh + c] = (float)IVCAMMapSample(src, i, c, srcCh, targetCh) / 32768.0f;
            ioData->mBuffers[0].mDataByteSize = wf * targetCh * (UInt32)sizeof(float);
        }
    } else {
        if (nonInterleaved) {
            for (UInt32 ch = 0; ch < targetCh; ch++) {
                int16_t *out = (int16_t *)ioData->mBuffers[ch].mData;
                UInt32 wf = ioData->mBuffers[ch].mDataByteSize / (UInt32)sizeof(int16_t);
                if (wf > inNumberFrames) wf = inNumberFrames;
                for (UInt32 i = 0; i < wf; i++)
                    out[i] = IVCAMMapSample(src, i, ch, srcCh, targetCh);
                ioData->mBuffers[ch].mDataByteSize = wf * (UInt32)sizeof(int16_t);
            }
        } else {
            int16_t *out = (int16_t *)ioData->mBuffers[0].mData;
            UInt32 wf = ioData->mBuffers[0].mDataByteSize / ((UInt32)sizeof(int16_t) * targetCh);
            if (wf > inNumberFrames) wf = inNumberFrames;
            for (UInt32 i = 0; i < wf; i++)
                for (UInt32 c = 0; c < targetCh; c++)
                    out[i * targetCh + c] = IVCAMMapSample(src, i, c, srcCh, targetCh);
            ioData->mBuffers[0].mDataByteSize = wf * targetCh * (UInt32)sizeof(int16_t);
        }
    }
    return YES;
}

static OSStatus IVCAMMediaActiveAudioUnitRender(AudioUnit inUnit,
                                                AudioUnitRenderActionFlags *ioActionFlags,
                                                const AudioTimeStamp *inTimeStamp,
                                                UInt32 inOutputBusNumber,
                                                UInt32 inNumberFrames,
                                                AudioBufferList *ioData) {
    OSStatus status = gOriginalAudioUnitRender
        ? gOriginalAudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData)
        : noErr;
    if (status != noErr || !ioData) return status;

    // Only the mic-INPUT element (bus 1 on RemoteIO/VPIO) is ever replaced. Output
    // elements (bus 0 = speaker) are left untouched so playback is never affected.
    if (inOutputBusNumber != 1) return status;
    if (!__atomic_load_n(&gEnabled, __ATOMIC_ACQUIRE)) return status;

    __atomic_add_fetch(&gRenderCalls, 1, __ATOMIC_RELAXED);

    if (IVCAMFillFromFifo(inUnit, inOutputBusNumber, inNumberFrames, ioData)) {
        __atomic_add_fetch(&gReplaced, 1, __ATOMIC_RELAXED);
        return status;
    }

    // Couldn't supply OBS audio (no stream / rate mismatch / underrun). Mic-leak
    // guard: if OBS audio is actively flowing (produced within the recent window)
    // this is a momentary gap in a live stream -> MUTE so the real mic never leaks
    // into the recording. Otherwise (video-only stream, or the pre-first-frame
    // startup window) fall open to the real mic so ordinary recording works.
    if (__atomic_load_n(&gOBSStreaming, __ATOMIC_ACQUIRE)) {
        uint64_t lastProd = __atomic_load_n(&gLastProducedUs, __ATOMIC_ACQUIRE);
        uint64_t nowUs = IVCAMNowUs();
        if (lastProd != 0 && nowUs >= lastProd && (nowUs - lastProd) < IVCAM_RECENT_AUDIO_US) {
            IVCAMMuteRT(ioData);
            __atomic_add_fetch(&gMuted, 1, __ATOMIC_RELAXED);
        }
    }
    return status;
}

// ---------------------------------------------------------------------------
// Background telemetry + maintenance (dispatch timer, off-RT)
// ---------------------------------------------------------------------------
static void IVCAMAudioBackgroundTick(void) {
    IVCAMAudioReloadPrefs(NO);

    os_unfair_lock_lock(&gAudioLock);
    uint32_t fill = gWriteIdx - gReadIdx;
    uint32_t rate = gFifoRate, ch = gFifoChannels;
    os_unfair_lock_unlock(&gAudioLock);
    uint32_t fillMs = (rate && ch) ? (uint32_t)((uint64_t)fill * 1000ull / ((uint64_t)rate * ch)) : 0;

    int64_t vpts = __atomic_load_n(&gVideoPTSms, __ATOMIC_ACQUIRE);
    int64_t apts = __atomic_load_n(&gAudioWritePTSms, __ATOMIC_ACQUIRE);
    uint32_t packed = __atomic_load_n(&gFmtPacked, __ATOMIC_ACQUIRE);
    IVCAMAudioLog(@"AUDIO_STATS render=%llu replaced=%llu underruns=%llu muted=%llu overflow=%llu unsupported=%llu "
                   "fifoRate=%u fifoCh=%u fill=%u fillMs=%u obs=%d leadMs=%lld unitRate=%u unitCh=%u unitFloat=%u unitNI=%u",
                  __atomic_load_n(&gRenderCalls, __ATOMIC_RELAXED),
                  __atomic_load_n(&gReplaced, __ATOMIC_RELAXED),
                  __atomic_load_n(&gUnderruns, __ATOMIC_RELAXED),
                  __atomic_load_n(&gMuted, __ATOMIC_RELAXED),
                  __atomic_load_n(&gOverflowDrops, __ATOMIC_RELAXED),
                  __atomic_load_n(&gUnsupported, __ATOMIC_RELAXED),
                  rate, ch, fill, fillMs, __atomic_load_n(&gOBSStreaming, __ATOMIC_ACQUIRE),
                  (apts > 0 && vpts > 0) ? (apts - vpts) : 0,
                  packed & 0x3FFFFu, (packed >> 18) & 0x3u, (packed >> 20) & 1u, (packed >> 21) & 1u);
}

static void IVCAMAudioStartBackground(void) {
    static dispatch_source_t timer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t queue = dispatch_queue_create("com.iosvcam.audiobridge.media-active.telemetry",
                                                        DISPATCH_QUEUE_SERIAL);
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                                  2 * NSEC_PER_SEC, (uint64_t)(0.25 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{ @autoreleasepool { IVCAMAudioBackgroundTick(); } });
        dispatch_resume(timer);
    });
}

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------
%ctor {
    @autoreleasepool {
#if VCAM_AUDIO_DISABLE
        // Video-only A/B build: install nothing (no hook, no producer symbols
        // effect). The Push/SetVideoPTS/SetOBSStreaming symbols still link (called
        // by the video path) but are inert here.
        return;
#endif
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *processName = [[NSProcessInfo processInfo] processName] ?: @"";
        BOOL targetProcess = [bundleID isEqualToString:IVCAM_AUDIO_TARGET_BUNDLE] ||
                             [processName isEqualToString:IVCAM_AUDIO_TARGET_PROCESS];

        IVCAMAudioLog(@"AUDIO_LOADED bundle=%@ process=%@ uid=%d target=%d",
                      bundleID, processName, getuid(), targetProcess);

        if (IVCAMAudioPathExists(IVCAM_AUDIO_DISABLE_FLAG)) {
            IVCAMAudioLog(@"AUDIO_DISABLED by file flag");
            return;
        }
        // A/B fps diagnostic: video-only if this marker exists (Media is a path
        // mediaserverd's sandbox can stat, unlike /var/tmp).
        if (IVCAMAudioPathExists(@"/var/mobile/Media/vcam_noaudio")) {
            IVCAMAudioLog(@"AUDIO_DISABLED by /var/mobile/Media/vcam_noaudio (video-only fps test)");
            return;
        }
        if (!targetProcess) {
            IVCAMAudioLog(@"AUDIO_INACTIVE not media target");
            return;
        }

        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        gTbNumer = tb.numer ? tb.numer : 1;
        gTbDenom = tb.denom ? tb.denom : 1;

        IVCAMAudioReloadPrefs(YES);
        IVCAMAudioStartBackground();

        MSHookFunction((void *)AudioUnitRender, (void *)IVCAMMediaActiveAudioUnitRender,
                       (void **)&gOriginalAudioUnitRender);
        IVCAMAudioLog(@"AUDIO_READY broadcast AudioUnitRender hook installed (shared FIFO, no latch)");
    }
}

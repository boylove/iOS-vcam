// ---------------------------------------------------------------------------
// OpenVCam — audio subsystem (GLOBAL, mediaserverd). Merged from
// ios/audio_bridge_media_active_tweak. Its %ctor self-gates to mediaserverd
// (same process as the OpenVCam video hooks), so it replaces microphone audio
// for EVERY capture client — the stock Camera, TikTok, all apps — the audio
// analogue of the in-place video overwrite. Real-time-safe (lock-free ring +
// jitter buffer), fail-open everywhere (any error / no bridge -> real mic).
//
// This REPLACES the old per-app VCamAudio.x (TikTok-only). Note: the stock
// Camera photo->video transition is the highest-risk path; the previous freeze
// came from having several competing audio packages installed at once — here
// there is a single fail-open hook. Recovery if anything wedges: remove the
// package + `killall mediaserverd` (mediaserverd's sandbox may block the file
// kill-switch, same as the video config — EXECUTION-PLAN §4.4).
// ---------------------------------------------------------------------------
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <substrate.h>
#import <arpa/inet.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <math.h>
#import <mach/mach_time.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <syslog.h>
#import <unistd.h>

// iOS-VCAM AudioBridge media-active hook (Phase 3: real-time-safe + jitter buffer).
//
// This tweak replaces mediaserverd microphone audio with PCM streamed from the PC
// AudioBridge (127.10.10.10:1936). The hook runs on the CoreAudio *render thread*,
// which is a hard real-time context. The design therefore splits work strictly:
//
//   * Producer  (single network thread): connect, parse hello, resample/channel-map,
//     enqueue into a lock-free ring. Allocation/logging are allowed here.
//   * Consumer  (AudioUnitRender hook, render thread): atomic index loads + memcpy +
//     fixed-point conversion + fade only. NO ObjC msgSend, NO CoreAudio property
//     calls, NO logging, NO malloc, NO locks in the hot path.
//   * Background (dispatch timer): poll CFPreferences, emit all stats/telemetry,
//     re-latch on idle. Never touches the render hot path directly.
//
// AudioUnitRender is a *global* hook and may be entered concurrently by several
// render threads (mediaserverd services many units). A single-producer/single-
// consumer ring is only safe with one consumer, so the hook latches exactly one
// AudioUnit+bus and falls open (original audio) for every other unit. All other
// paths also fall open, preserving the package's fail-open contract.
//
// Wire format is Phase-2 compatible: 28-byte little-endian header
// {char magic[4]="IAF1"; uint32 sequence; uint64 ptsUS; uint64 durationUS;
//  uint32 payloadLength;} followed by signed-16-bit interleaved PCM.

#define IVCAM_MEDIA_ACTIVE_PREFS @"/var/mobile/Library/Preferences/com.iosvcam.audiobridge.media-active.plist"
#define IVCAM_MEDIA_ACTIVE_DISABLE_FLAG @"/var/mobile/Library/Preferences/com.iosvcam.audiobridge.media-active.disabled"
#define IVCAM_MEDIA_ACTIVE_PREFS_DOMAIN CFSTR("com.iosvcam.audiobridge.media-active")
#define IVCAM_MEDIA_ACTIVE_LOG @"iOSVCAMAudioBridgeMediaActive.log"
#define IVCAM_MEDIA_ACTIVE_MAGIC "IAF1"
#define IVCAM_MEDIA_ACTIVE_TARGET_BUNDLE @"com.apple.mediaserverd"
#define IVCAM_MEDIA_ACTIVE_TARGET_PROCESS @"mediaserverd"

// Ring holds target-format interleaved int16. 1<<17 samples = 256 KiB, ~1.37 s of
// 48 kHz stereo / ~2.73 s mono, far above the 60-100 ms jitter water level.
#define IVCAM_RING_SAMPLES (1u << 17)
#define IVCAM_RING_MASK (IVCAM_RING_SAMPLES - 1u)
#define IVCAM_MAX_RENDER_FRAMES 8192u
#define IVCAM_SCRATCH_SAMPLES (IVCAM_MAX_RENDER_FRAMES * 2u)

// Producer-thread-only scratch (single owner -> no locking). One 64 KiB payload is
// at most 32768 source samples; mono->stereo doubles to 65536; the resampler output
// is bounded by IVCAM_PROD_OUT_SAMPLES (drops any tail beyond it, counted).
#define IVCAM_MAX_PAYLOAD_BYTES 65536u
#define IVCAM_PROD_MIX_SAMPLES 65536u
#define IVCAM_PROD_OUT_SAMPLES 131072u

// 150 ms cushion (was 80): the audio arrives over an SSH reverse tunnel that
// batches TCP, so it comes in bursts; a bigger jitter buffer absorbs them and
// cuts the start-up underruns. Raise via the JitterMs pref if the tunnel is worse.
#define IVCAM_JITTER_MS_DEFAULT 120u
#define IVCAM_JITTER_MS_MIN 20u
#define IVCAM_JITTER_MS_MAX 400u
#define IVCAM_RELATCH_IDLE_US 3000000ull
// Fast latch STEAL: when a different mic unit is actively rendering while the latched unit has not
// replaced for this long, release the latch immediately so the active unit (e.g. TikTok's just-
// opened recorder) takes over in ~this time instead of waiting for the 3s background idle-relatch.
#define IVCAM_STEAL_IDLE_US 250000ull

#pragma pack(push, 1)
typedef struct {
    char magic[4];
    uint32_t sequence;
    uint64_t ptsUS;
    uint64_t durationUS;
    uint32_t payloadLength;
} IVCAMMediaActiveFrameHeader;
#pragma pack(pop)

// Shared state. Everything the render hot path reads lives here as plain C so the
// render thread never sends an ObjC message. Cross-thread fields use __atomic;
// the storage is otherwise ordinary POD in BSS (zero-initialised, no heap).
typedef struct {
    int16_t buf[IVCAM_RING_SAMPLES];  // target-format interleaved int16

    uint32_t writeIdx;  // producer-owned; consumer acquire-loads
    uint32_t readIdx;   // consumer-owned; producer acquire-loads

    uint32_t enabled;             // background store-release; hot path acquire-loads
    uint32_t targetWaterSamples;  // jitter water level, in int16 samples
    uint32_t formatReady;         // release/acquire gate for the tgt* block below
    uint32_t primed;              // consumer-owned

    uint32_t tgtRate;            // latched output format (cached once, read lock-free)
    uint32_t tgtChannels;
    uint32_t tgtIsFloat;
    uint32_t tgtBits;
    uint32_t tgtNonInterleaved;
    uint32_t consumerBus;

    void *consumerUnit;  // latched consumer AudioUnit (NULL until latched)

    int16_t lastOut[2];        // consumer-owned fade seed (last emitted sample/ch)
    uint32_t starveRun;        // consumer-owned consecutive full-underrun count
    uint32_t latchLogPending;  // RT -> background one-shot latch log request
    uint64_t lastRenderUs;     // RT stamps each replaced render for idle re-latch

    uint64_t renderCalls;    // stat counters (RELAXED adds)
    uint64_t replaced;
    uint64_t underruns;
    uint64_t trimDrops;
    uint64_t overflowDrops;
    uint64_t unsupported;
    uint64_t parkedFrames;

    uint64_t renderNsMax;   // render timing (RELAXED)
    uint64_t renderNsLast;
    uint64_t periodOverruns;

    uint32_t tbNumer;  // mach timebase, cached once at ctor
    uint32_t tbDenom;

    int16_t scratch[IVCAM_SCRATCH_SAMPLES];  // consumer read scratch
} IVCAMMediaActiveCtx;

static IVCAMMediaActiveCtx gCtx;
static uint32_t gConsumerRead = 0;   // consumer-owned mirror of readIdx
static uint32_t gProducerWrite = 0;  // producer-owned mirror of writeIdx

// Producer scratch (producer thread only, single owner).
static uint8_t gProducerRecv[IVCAM_MAX_PAYLOAD_BYTES];
static int16_t gProducerMix[IVCAM_PROD_MIX_SAMPLES];
static int16_t gProducerOut[IVCAM_PROD_OUT_SAMPLES];

// Config globals (written by ctor + background prefs poll, read off-RT).
static char gHostC[128] = "127.10.10.10";
static int gPortC = 1936;
static uint32_t gSrcRateHint = 48000;   // hello overrides; prefs are only a fallback
static uint32_t gSrcChHint = 1;
static uint32_t gJitterMs = IVCAM_JITTER_MS_DEFAULT;
static uint32_t gProducerStarted = 0;

// Audio source mode. 1 (default) = OBS audio is demuxed from the SAME RTMP stream the video
// path already pulls (VCamRTMPSource pushes decoded PCM via IVCAMMediaActivePushPCM). 0 = the
// legacy standalone PCM bridge on :1936. In RTMP mode the :1936 socket producer stays dormant so
// there is exactly ONE producer feeding the SPSC ring/scratch.
static uint32_t gAudioSourceRTMP = 1;

// Set by the RTMP source (VCamRTMPSource) on connect/disconnect: 1 = OBS is streaming, so OBS
// audio is expected. While set, a mic-input render (bus 1) is NEVER allowed to record the real
// mic — it is muted whenever it can't yet be replaced with OBS audio (latching, priming, or a
// non-latched mic unit). Cleared when OBS stops, so a no-OBS recording falls open to the real mic.
static volatile int32_t gVCamOBSStreaming = 0;
void IVCAMSetOBSStreaming(int on) { __atomic_store_n(&gVCamOBSStreaming, on ? 1 : 0, __ATOMIC_RELEASE); }

// Dynamic A/V sync: RTMP PTS (ms) of the currently-displayed video frame (published by the H264
// decoder) and of the newest audio sample written to the ring (published by the producer). The
// consumer buffers ~(gAudioWritePTSms - gVideoPTSms) so the audio it plays lands on the shown
// video's PTS. Both from the same OBS stream's timeline, so directly comparable; 0 = unknown.
static volatile int64_t gVideoPTSms = 0;
static volatile int64_t gAudioWritePTSms = 0;
void IVCAMSetVideoPTS(int64_t ptsMs) { __atomic_store_n(&gVideoPTSms, ptsMs, __ATOMIC_RELEASE); }

static OSStatus (*gOriginalAudioUnitRender)(AudioUnit inUnit,
                                            AudioUnitRenderActionFlags *ioActionFlags,
                                            const AudioTimeStamp *inTimeStamp,
                                            UInt32 inOutputBusNumber,
                                            UInt32 inNumberFrames,
                                            AudioBufferList *ioData) = NULL;

#pragma mark - Atomic helpers (mirrors audio_bridge_daemon.c:59-73)

static inline uint64_t IVCAMAtomicAdd64(uint64_t *field, uint64_t amount) {
    return __atomic_add_fetch(field, amount, __ATOMIC_RELAXED);
}
static inline void IVCAMAtomicStore32(uint32_t *field, uint32_t value) {
    __atomic_store_n(field, value, __ATOMIC_RELEASE);
}
static inline uint32_t IVCAMAtomicLoad32(uint32_t *field) {
    return __atomic_load_n(field, __ATOMIC_ACQUIRE);
}
static inline void IVCAMAtomicStore64(uint64_t *field, uint64_t value) {
    __atomic_store_n(field, value, __ATOMIC_RELEASE);
}
static inline uint64_t IVCAMAtomicLoad64(uint64_t *field) {
    return __atomic_load_n(field, __ATOMIC_ACQUIRE);
}

// Monotonic microseconds from the mach clock (mach_absolute_time is commpage-backed
// and real-time safe). tbNumer/tbDenom are cached once at ctor.
static inline uint64_t IVCAMNowUs(void) {
    return (mach_absolute_time() * (uint64_t)gCtx.tbNumer / (uint64_t)gCtx.tbDenom) / 1000ull;
}

#pragma mark - Logging (off-render-thread only)

static NSArray<NSString *> *IVCAMMediaActiveLogPaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    [paths addObject:[@"/var/mobile/Library/Logs" stringByAppendingPathComponent:IVCAM_MEDIA_ACTIVE_LOG]];
    [paths addObject:[@"/var/tmp" stringByAppendingPathComponent:IVCAM_MEDIA_ACTIVE_LOG]];

    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length > 0) {
        [paths addObject:[tmp stringByAppendingPathComponent:IVCAM_MEDIA_ACTIVE_LOG]];
    }
    [paths addObject:[@"/tmp" stringByAppendingPathComponent:IVCAM_MEDIA_ACTIVE_LOG]];
    return paths;
}

static void IVCAMMediaActiveRotateIfNeeded(NSString *path) {
    NSDictionary<NSFileAttributeKey, id> *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSNumber *size = attrs[NSFileSize];
    if (size && [size unsignedLongLongValue] > 131072) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
}

static BOOL IVCAMMediaActiveAppendLog(NSString *path, NSData *data) {
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    IVCAMMediaActiveRotateIfNeeded(path);

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return [data writeToFile:path atomically:NO];
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return NO;

    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
        return YES;
    } @catch (NSException *exception) {
        @try { [handle closeFile]; } @catch (NSException *closeException) { }
        return NO;
    }
}

// Real-time note: only call from the ctor, producer, or background threads.
static void IVCAMMediaActiveLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *path in IVCAMMediaActiveLogPaths()) {
        if (IVCAMMediaActiveAppendLog(path, data)) break;
    }

    const char *utf8 = [message UTF8String];
    if (utf8) {
        syslog(LOG_NOTICE, "[iOSVCAMAudioBridgeMediaActive] %s", utf8);
    }
    NSLog(@"[iOSVCAMAudioBridgeMediaActive] %@", message);
}

#pragma mark - Preferences (off-render-thread only)

static id IVCAMMediaActiveCopyPref(NSString *key) {
    CFPreferencesAppSynchronize(IVCAM_MEDIA_ACTIVE_PREFS_DOMAIN);
    CFTypeRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, IVCAM_MEDIA_ACTIVE_PREFS_DOMAIN);
    return CFBridgingRelease(value);
}

static BOOL IVCAMMediaActivePathExists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

// Recompute the jitter water level in ring samples from the current JitterMs and
// the latched output format. Only meaningful once formatReady is set.
static void IVCAMMediaActiveRecomputeWater(void) {
    if (!IVCAMAtomicLoad32(&gCtx.formatReady)) return;
    uint32_t rate = gCtx.tgtRate ? gCtx.tgtRate : 48000u;
    uint32_t ch = gCtx.tgtChannels ? gCtx.tgtChannels : 1u;
    uint32_t samples = (uint32_t)((uint64_t)gJitterMs * rate / 1000ull) * ch;
    IVCAMAtomicStore32(&gCtx.targetWaterSamples, samples);
}

// Reloads CFPreferences/file flags into the config globals + gCtx.enabled.
// Returns the resolved enabled state. Off-render-thread only.
static BOOL IVCAMMediaActiveReloadPrefs(BOOL verbose) {
    id disabledPref = IVCAMMediaActiveCopyPref(@"Disabled");
    BOOL disabled = ([disabledPref respondsToSelector:@selector(boolValue)] && [disabledPref boolValue]) ||
                    IVCAMMediaActivePathExists(IVCAM_MEDIA_ACTIVE_DISABLE_FLAG);
    if (disabled) {
        IVCAMAtomicStore32(&gCtx.enabled, 0);
        if (verbose) IVCAMMediaActiveLog(@"MEDIA_ACTIVE_PREFS disabled by flag");
        return NO;
    }

    NSDictionary *filePrefs = [NSDictionary dictionaryWithContentsOfFile:IVCAM_MEDIA_ACTIVE_PREFS];
    id enabledValue = IVCAMMediaActiveCopyPref(@"Enabled") ?: filePrefs[@"Enabled"];
    id hostValue = IVCAMMediaActiveCopyPref(@"Host") ?: filePrefs[@"Host"];
    id portValue = IVCAMMediaActiveCopyPref(@"Port") ?: filePrefs[@"Port"];
    id sampleRateValue = IVCAMMediaActiveCopyPref(@"SampleRate") ?: filePrefs[@"SampleRate"];
    id channelsValue = IVCAMMediaActiveCopyPref(@"Channels") ?: filePrefs[@"Channels"];
    id jitterValue = IVCAMMediaActiveCopyPref(@"JitterMs") ?: filePrefs[@"JitterMs"];

    BOOL hasEnabledValue = [enabledValue respondsToSelector:@selector(boolValue)];
    BOOL enabled = hasEnabledValue ? [enabledValue boolValue] : YES;
    if ([hostValue isKindOfClass:[NSString class]] && [hostValue length] > 0) {
        strlcpy(gHostC, [hostValue UTF8String], sizeof(gHostC));
    }
    if ([portValue respondsToSelector:@selector(intValue)] && [portValue intValue] > 0) {
        gPortC = [portValue intValue];
    }
    if ([sampleRateValue respondsToSelector:@selector(intValue)] && [sampleRateValue intValue] > 0) {
        gSrcRateHint = (uint32_t)[sampleRateValue intValue];
    }
    if ([channelsValue respondsToSelector:@selector(intValue)] &&
        ([channelsValue intValue] == 1 || [channelsValue intValue] == 2)) {
        gSrcChHint = (uint32_t)[channelsValue intValue];
    }
    if ([jitterValue respondsToSelector:@selector(intValue)] && [jitterValue intValue] > 0) {
        uint32_t ms = (uint32_t)[jitterValue intValue];
        if (ms < IVCAM_JITTER_MS_MIN) ms = IVCAM_JITTER_MS_MIN;
        if (ms > IVCAM_JITTER_MS_MAX) ms = IVCAM_JITTER_MS_MAX;
        gJitterMs = ms;
    }

    IVCAMAtomicStore32(&gCtx.enabled, enabled ? 1 : 0);
    IVCAMMediaActiveRecomputeWater();

    if (verbose) {
        IVCAMMediaActiveLog(@"MEDIA_ACTIVE_PREFS enabled=%d host=%s port=%d srcRate=%u srcCh=%u jitterMs=%u source=%@",
                            enabled, gHostC, gPortC, gSrcRateHint, gSrcChHint, gJitterMs,
                            hasEnabledValue ? @"prefs" : @"default");
    }
    return enabled;
}

#pragma mark - Socket helpers (producer thread)

static BOOL IVCAMMediaActiveReadExact(int fd, void *buffer, size_t length) {
    uint8_t *cursor = (uint8_t *)buffer;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t n = recv(fd, cursor, remaining, 0);
        if (n <= 0) return NO;
        cursor += n;
        remaining -= (size_t)n;
    }
    return YES;
}

// Parse an unsigned int JSON value out of the hello line (mirrors
// IVCAMParseHelloUInt, audio_bridge_daemon.c:134). The bridge hello is
// authoritative for the source format; prefs are only a fallback.
static uint32_t IVCAMMediaActiveParseHelloUInt(const char *hello, const char *key, uint32_t fallback) {
    if (!hello || !key) return fallback;
    char needle[64];
    snprintf(needle, sizeof(needle), "\"%s\":", key);
    const char *cursor = strstr(hello, needle);
    if (!cursor) return fallback;
    cursor += strlen(needle);
    while (*cursor == ' ' || *cursor == '\t') cursor++;
    char *end = NULL;
    unsigned long value = strtoul(cursor, &end, 10);
    if (end == cursor || value == 0 || value > UINT32_MAX) return fallback;
    return (uint32_t)value;
}

#pragma mark - Ring buffer (SPSC, lock-free)

// Producer enqueue of `n` interleaved int16 target-format samples. Whole frames
// only. Overflow drops the newest payload (SPSC-legal: the producer owns writeIdx
// and may never touch readIdx). The release-store publishes the data memcpy.
static void IVCAMRingWrite(const int16_t *src, uint32_t n) {
    if (n == 0) return;
    uint32_t w = gProducerWrite;
    uint32_t r = IVCAMAtomicLoad32(&gCtx.readIdx);
    // Latency backstop: if the consumer has fallen far behind (stalled, or a wrong/idle unit
    // latched so nobody drains), the backlog would play seconds-stale and wreck lip-sync. Discard
    // the whole backlog and resume writing fresh from the read point, so audio latency is bounded
    // regardless of the consumer. SPSC-safe: the producer owns writeIdx, and a consumer this far
    // behind is not draining, so no live read is corrupted (worst case one faded frame).
    uint32_t backlogCap = gCtx.targetWaterSamples
        ? (gCtx.targetWaterSamples + (gCtx.targetWaterSamples >> 1)) : 16384u;  // 1.5x water
    if (w - r > backlogCap) {
        IVCAMAtomicAdd64(&gCtx.overflowDrops, w - r);
        w = r;
        gProducerWrite = w;
        IVCAMAtomicStore32(&gCtx.writeIdx, w);
    }
    uint32_t used = w - r;
    uint32_t freeSamples = IVCAM_RING_SAMPLES - used;
    if (n > freeSamples) {
        IVCAMAtomicAdd64(&gCtx.overflowDrops, 1);
        return;
    }
    uint32_t pos = w & IVCAM_RING_MASK;
    uint32_t first = IVCAM_RING_SAMPLES - pos;
    if (first > n) first = n;
    memcpy(&gCtx.buf[pos], src, (size_t)first * sizeof(int16_t));
    if (n > first) {
        memcpy(&gCtx.buf[0], src + first, (size_t)(n - first) * sizeof(int16_t));
    }
    w += n;
    gProducerWrite = w;
    IVCAMAtomicStore32(&gCtx.writeIdx, w);
}

#pragma mark - Producer channel map + resample (producer thread)

static void IVCAMChannelMap(const int16_t *in, uint32_t frames, uint32_t inCh,
                            int16_t *out, uint32_t outCh) {
    if (inCh == 1 && outCh == 2) {
        for (uint32_t i = 0; i < frames; i++) {
            int16_t s = in[i];
            out[2 * i] = s;
            out[2 * i + 1] = s;
        }
    } else if (inCh == 2 && outCh == 1) {
        for (uint32_t i = 0; i < frames; i++) {
            out[i] = (int16_t)(((int32_t)in[2 * i] + (int32_t)in[2 * i + 1]) / 2);
        }
    } else {
        uint32_t common = inCh < outCh ? inCh : outCh;
        for (uint32_t i = 0; i < frames; i++) {
            for (uint32_t c = 0; c < common; c++) out[i * outCh + c] = in[i * inCh + c];
            for (uint32_t c = common; c < outCh; c++) out[i * outCh + c] = 0;
        }
    }
}

// Lightweight linear-interpolation resampler (fallback for src rate != target).
// Resamples one input block independently (bounds-clamped, no cross-block phase
// state); the sub-millisecond per-block boundary error is absorbed by the jitter
// buffer and is irrelevant on the common 48 kHz passthrough path (never called).
static uint32_t IVCAMResampleLinear(const int16_t *in, uint32_t inFrames, uint32_t ch,
                                    uint32_t srcRate, uint32_t tgtRate,
                                    int16_t *out, uint32_t outCapFrames) {
    if (inFrames < 2) return 0;
    double step = (double)srcRate / (double)tgtRate;
    double pos = 0.0;
    uint32_t o = 0;
    while (o < outCapFrames && pos < (double)(inFrames - 1)) {
        long idx = (long)pos;
        double frac = pos - (double)idx;
        for (uint32_t c = 0; c < ch; c++) {
            int16_t a = in[idx * ch + c];
            int16_t b = in[(idx + 1) * ch + c];
            out[o * ch + c] = (int16_t)lround((double)a + ((double)b - (double)a) * frac);
        }
        o++;
        pos += step;
    }
    return o;
}

// Adapt `srcFrames` interleaved int16 PCM (srcRate/srcCh) to the latched consumer format and
// enqueue into the ring. Producer-thread-only (uses the single-owner producer scratch). Parks
// (drops + counts) until the render thread has latched a unit and published its target format,
// so wrong-rate data can never enter the ring. Called by BOTH the :1936 socket producer AND the
// RTMP-audio producer (VCamRTMPSource, msg_type 8) — but only ONE of them runs at a time (see
// gAudioSourceRTMP), so the shared scratch + SPSC ring stay single-producer-safe. NOT real-time
// safe (allocation-free but not for the render thread); call only from an off-RT producer thread.
void IVCAMMediaActivePushPCM(const int16_t *pcm, uint32_t srcFrames,
                             uint32_t srcRate, uint32_t srcCh, int64_t ptsMs) {
    if (!pcm || srcFrames == 0 || !(srcCh == 1 || srcCh == 2)) return;

    // Publish the PTS of the newest sample in this frame (start + duration) for dynamic A/V sync.
    if (ptsMs > 0 && srcRate > 0)
        __atomic_store_n(&gAudioWritePTSms, ptsMs + (int64_t)srcFrames * 1000 / (int64_t)srcRate,
                         __ATOMIC_RELEASE);


    // Park until a unit has latched its target format (no wrong-rate data into the ring).
    if (!IVCAMAtomicLoad32(&gCtx.formatReady)) {
        IVCAMAtomicAdd64(&gCtx.parkedFrames, 1);
        return;
    }
    uint32_t tgtRate = gCtx.tgtRate;
    uint32_t tgtCh = gCtx.tgtChannels;
    if (!(tgtCh == 1 || tgtCh == 2) || tgtRate == 0) return;

    // 1) channel map source -> target channels (at source rate)
    const int16_t *mixed;
    uint32_t mixedFrames = srcFrames;
    if (srcCh == tgtCh) {
        mixed = pcm;
    } else {
        if (srcFrames * tgtCh > IVCAM_PROD_MIX_SAMPLES) return;
        IVCAMChannelMap(pcm, srcFrames, srcCh, gProducerMix, tgtCh);
        mixed = gProducerMix;
    }

    // 2) resample source rate -> target rate
    const int16_t *finalPcm;
    uint32_t finalFrames;
    if (srcRate == tgtRate) {
        finalPcm = mixed;
        finalFrames = mixedFrames;
    } else {
        finalFrames = IVCAMResampleLinear(mixed, mixedFrames, tgtCh, srcRate, tgtRate,
                                          gProducerOut, IVCAM_PROD_OUT_SAMPLES / tgtCh);
        finalPcm = gProducerOut;
    }

    // 3) enqueue
    IVCAMRingWrite(finalPcm, finalFrames * tgtCh);
}

#pragma mark - Producer network loop

static void IVCAMMediaActiveProducerLoop(void) {
    uint64_t connectAttempts = 0;
    while (1) {
        // Idle (do not connect) while disabled; stay alive so a later enable can
        // reconnect without needing to respawn the thread.
        if (!IVCAMAtomicLoad32(&gCtx.enabled)) {
            sleep(1);
            continue;
        }
        // In RTMP-source mode the audio comes from VCamRTMPSource (single producer), so the
        // legacy :1936 socket producer must stay dormant to preserve the SPSC invariant.
        if (gAudioSourceRTMP) {
            sleep(1);
            continue;
        }
        @autoreleasepool {
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) {
                connectAttempts++;
                if (connectAttempts <= 5 || (connectAttempts % 500) == 0) {
                    IVCAMMediaActiveLog(@"MEDIA_ACTIVE_SOCKET_FAILED errno=%d", errno);
                }
                sleep(1);
                continue;
            }

            char host[128];
            strlcpy(host, gHostC, sizeof(host));
            int port = gPortC;

            struct sockaddr_in addr;
            memset(&addr, 0, sizeof(addr));
            addr.sin_family = AF_INET;
            addr.sin_port = htons((uint16_t)port);
            if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
                close(fd);
                IVCAMMediaActiveLog(@"MEDIA_ACTIVE_BAD_HOST %s", host);
                sleep(1);
                continue;
            }

            if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
                int err = errno;
                close(fd);
                connectAttempts++;
                if (connectAttempts <= 5 || (connectAttempts % 15) == 0) {
                    IVCAMMediaActiveLog(@"MEDIA_ACTIVE_CONNECT_WAIT host=%s port=%d attempts=%llu errno=%d error=%s",
                                        host, port, connectAttempts, err, strerror(err));
                }
                sleep(1);
                continue;
            }

            connectAttempts = 0;
            IVCAMMediaActiveLog(@"MEDIA_ACTIVE_CONNECTED connected to %s:%d", host, port);

            // Read the ASCII hello line and parse the authoritative source format.
            char helloBuf[1024];
            NSUInteger helloBytes = 0;
            char c = 0;
            while (helloBytes < sizeof(helloBuf) - 1 && recv(fd, &c, 1, 0) == 1) {
                helloBuf[helloBytes++] = c;
                if (c == '\n') break;
            }
            helloBuf[helloBytes] = '\0';

            uint32_t srcRate = IVCAMMediaActiveParseHelloUInt(helloBuf, "sample_rate", gSrcRateHint);
            uint32_t srcCh = IVCAMMediaActiveParseHelloUInt(helloBuf, "channels", gSrcChHint);
            if (!(srcCh == 1 || srcCh == 2)) srcCh = 1;
            if (srcRate == 0 || srcRate > 192000) srcRate = 48000;
            if (helloBytes > 0) {
                IVCAMMediaActiveLog(@"MEDIA_ACTIVE_HELLO srcRate=%u srcCh=%u raw=%.*s",
                                    srcRate, srcCh, (int)(helloBytes > 200 ? 200 : helloBytes), helloBuf);
            }

            while (IVCAMAtomicLoad32(&gCtx.enabled)) {
                IVCAMMediaActiveFrameHeader header;
                if (!IVCAMMediaActiveReadExact(fd, &header, sizeof(header))) break;
                if (memcmp(header.magic, IVCAM_MEDIA_ACTIVE_MAGIC, 4) != 0) {
                    IVCAMMediaActiveLog(@"MEDIA_ACTIVE_BAD_FRAME_MAGIC sequence=%u", header.sequence);
                    break;
                }
                if (header.payloadLength == 0 || header.payloadLength > IVCAM_MAX_PAYLOAD_BYTES) {
                    IVCAMMediaActiveLog(@"MEDIA_ACTIVE_BAD_FRAME_LEN sequence=%u len=%u",
                                        header.sequence, header.payloadLength);
                    break;
                }
                if (!IVCAMMediaActiveReadExact(fd, gProducerRecv, header.payloadLength)) break;

                // Adapt to the latched target format and enqueue (parks until formatReady).
                uint32_t srcFrames = header.payloadLength / (srcCh * 2u);
                IVCAMMediaActivePushPCM((const int16_t *)gProducerRecv, srcFrames, srcRate, srcCh, 0);
            }

            close(fd);
            IVCAMMediaActiveLog(@"MEDIA_ACTIVE_DISCONNECTED bridge disconnected; retrying");
            sleep(1);
        }
    }
}

static void IVCAMMediaActiveStartProducer(void) {
    // dispatch_once semantics via atomic test-and-set: exactly one producer thread.
    uint32_t expected = 0;
    if (!__atomic_compare_exchange_n(&gProducerStarted, &expected, 1, false,
                                     __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        IVCAMMediaActiveProducerLoop();
    });
}

#pragma mark - Render hook (render thread; real-time safe)

// Attempt to latch this unit as the single consumer. Runs on the render thread but
// only before a unit is latched (while we are falling open to the real mic), so a
// one-time AudioUnitGetProperty here is safe: the unit is alive during its own
// render, and this cost disappears entirely once latched. Returns YES on success.
static BOOL IVCAMMediaActiveTryLatch(AudioUnit inUnit, UInt32 bus, AudioBufferList *ioData) {
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
    if (fs != noErr) {
        IVCAMAtomicAdd64(&gCtx.unsupported, 1);
        return NO;
    }

    BOOL isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    BOOL isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 channels = asbd.mChannelsPerFrame;
    if (channels == 0 && isNonInterleaved) channels = ioData->mNumberBuffers;

    if (asbd.mFormatID != kAudioFormatLinearPCM || !(channels == 1 || channels == 2) ||
        !((isFloat && asbd.mBitsPerChannel == 32) || (isSignedInt && asbd.mBitsPerChannel == 16)) ||
        asbd.mSampleRate <= 0.0 || asbd.mSampleRate > 192000.0) {
        IVCAMAtomicAdd64(&gCtx.unsupported, 1);
        return NO;
    }

    // Win the latch. CAS ensures a single writer of the target format fields even if
    // two units render concurrently before either has latched.
    void *expected = NULL;
    if (!__atomic_compare_exchange_n(&gCtx.consumerUnit, &expected, (void *)inUnit, false,
                                     __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        return NO;
    }

    gCtx.tgtRate = (uint32_t)asbd.mSampleRate;
    gCtx.tgtChannels = channels;
    gCtx.tgtIsFloat = isFloat ? 1 : 0;
    gCtx.tgtBits = asbd.mBitsPerChannel;
    gCtx.tgtNonInterleaved = isNonInterleaved ? 1 : 0;
    gCtx.consumerBus = bus;

    // Drain any stale (pre-latch) content and reset jitter state.
    uint32_t w = IVCAMAtomicLoad32(&gCtx.writeIdx);
    gConsumerRead = w;
    IVCAMAtomicStore32(&gCtx.readIdx, w);
    gCtx.primed = 0;
    gCtx.starveRun = 0;
    gCtx.lastOut[0] = 0;
    gCtx.lastOut[1] = 0;

    uint32_t water = (uint32_t)((uint64_t)gJitterMs * gCtx.tgtRate / 1000ull) * gCtx.tgtChannels;
    IVCAMAtomicStore32(&gCtx.targetWaterSamples, water);
    __atomic_store_n(&gCtx.latchLogPending, 1, __ATOMIC_RELAXED);

    // RELEASE publishes the tgt* fields written above to the producer.
    IVCAMAtomicStore32(&gCtx.formatReady, 1);
    return YES;
}

// Rate-limit gate for the unlatched-state format probe (TryLatch's AudioUnitGetProperty): its
// last attempt time in monotonic us. Calling AudioUnitGetProperty on EVERY unlatched render across
// TikTok's many VoiceProcessing units blew the HAL RT budget -> mediaserverd crash-loop.
static volatile uint64_t gLastLatchTryUs = 0;

// Real-time-safe: zero every buffer (silence the render output). Used to keep the real mic out
// of a recording when OBS is streaming but we can't (yet) supply OBS audio on this unit.
static inline void IVCAMMediaActiveMuteRT(AudioBufferList *ioData) {
    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++)
        if (ioData->mBuffers[i].mData)
            memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
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

    IVCAMAtomicAdd64(&gCtx.renderCalls, 1);

    // ONLY the mic-INPUT element (bus 1 on RemoteIO) is ever latched/replaced/muted. Output
    // elements (bus 0 = speaker) are left completely untouched: latching one would inject OBS
    // audio into playback AND (via the mic-leak guard) mute every real mic-input render -> a
    // silent recording. Restricting to bus 1 keeps the latch on the actual capture mic.
    if (inOutputBusNumber != 1) return status;
    if (!IVCAMAtomicLoad32(&gCtx.enabled)) return status;

    // A mic-INPUT element (bus 1) must never leak the real mic into a recording while OBS is
    // streaming: it is replaced with OBS audio when latched, otherwise MUTED. Output elements
    // (bus 0 = speaker) are never touched. When OBS is not streaming, muteLeak is false so mic
    // inputs fall open to the real mic (normal recording keeps working).
    BOOL muteLeak = (inOutputBusNumber == 1) &&
                    (__atomic_load_n(&gVCamOBSStreaming, __ATOMIC_ACQUIRE) != 0);

    void *consumer = __atomic_load_n(&gCtx.consumerUnit, __ATOMIC_ACQUIRE);
    if (consumer == NULL) {
        // Not latched yet. TryLatch does a synchronous AudioUnitGetProperty — NOT cheap on the RT
        // thread; running it on EVERY unlatched render across TikTok's many VoiceProcessing units
        // blew the HAL budget -> mediaserverd crash-loop. Rate-limit to ~one probe / 200ms (global,
        // across all units); muting (never real mic) covers the gap while OBS streams.
        uint64_t nowUs = IVCAMNowUs();
        uint64_t lastTry = __atomic_load_n(&gLastLatchTryUs, __ATOMIC_RELAXED);
        if (nowUs - lastTry > 200000ull) {
            __atomic_store_n(&gLastLatchTryUs, nowUs, __ATOMIC_RELAXED);
            IVCAMMediaActiveTryLatch(inUnit, inOutputBusNumber, ioData);
        }
        if (muteLeak) IVCAMMediaActiveMuteRT(ioData);
        return status;
    }
    if (consumer != (void *)inUnit) {               // a different mic unit -> mute, never real mic
        // Fast steal on app switch: if THIS unit is actively rendering but the latched unit has
        // gone idle (stopped replacing), release the latch now so this unit can take over on its
        // next render (~STEAL + one rate-limited probe), instead of muting for the whole clip while
        // the 3s background idle-relatch catches up. This is what makes a freshly-opened TikTok
        // recorder get OBS audio quickly. CAS so only one thread clears a given stale latch.
        uint64_t lastUs = IVCAMAtomicLoad64(&gCtx.lastRenderUs);
        uint64_t nowUs = IVCAMNowUs();
        if (lastUs != 0 && nowUs > lastUs && (nowUs - lastUs) > IVCAM_STEAL_IDLE_US) {
            if (__atomic_compare_exchange_n(&gCtx.consumerUnit, &consumer, NULL, false,
                                            __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
                IVCAMAtomicStore32(&gCtx.formatReady, 0);
            }
        }
        if (muteLeak) IVCAMMediaActiveMuteRT(ioData);
        return status;
    }
    // This IS the latched unit rendering. Stamp liveness NOW — on EVERY render, even while still
    // priming (before the first replace) — so a unit that is merely warming up is not mistaken for
    // idle and STOLEN by another unit. That mis-steal caused perpetual re-latching so the unit
    // never finished priming (primed=0, replaced flat) -> silent, e.g. a freshly-opened TikTok
    // recorder. Goes stale only when the latched unit truly stops rendering (app switched away).
    IVCAMAtomicStore64(&gCtx.lastRenderUs, IVCAMNowUs());

    // formatReady (acquire) publishes consumerBus + the tgt* fields written before
    // its release at latch, so read them only after this gate.
    if (!IVCAMAtomicLoad32(&gCtx.formatReady)) return status;
    if (inOutputBusNumber != gCtx.consumerBus) return status;  // some other bus
    if (inNumberFrames == 0 || inNumberFrames > IVCAM_MAX_RENDER_FRAMES) return status;

    uint32_t tgtCh = gCtx.tgtChannels;
    if (!(tgtCh == 1 || tgtCh == 2)) return status;

    // Validate the buffer layout against the cached format BEFORE consuming, so a
    // layout mismatch falls open without losing ring data.
    BOOL nonInterleaved = gCtx.tgtNonInterleaved != 0;
    if (nonInterleaved) {
        if (ioData->mNumberBuffers < tgtCh) return status;
        for (uint32_t ch = 0; ch < tgtCh; ch++) {
            if (!ioData->mBuffers[ch].mData) return status;  // validate before consuming
        }
    } else {
        if (ioData->mNumberBuffers < 1 || !ioData->mBuffers[0].mData) return status;
    }

    uint64_t t0 = mach_absolute_time();

    uint32_t need = inNumberFrames * tgtCh;  // total samples to emit

    // DYNAMIC A/V SYNC target: buffer ~(newest-audio-PTS - displayed-video-PTS) so the audio we
    // play lands on the shown video's PTS, + a gJitterMs cushion for network jitter. Self-
    // correcting (no fixed delay): when the video pipeline latency or the network shifts, the PTS
    // difference shifts with it. Stored to targetWaterSamples so the producer's backlog cap and
    // the priming/trim below all track the same dynamic target. Falls back to the fixed jitter
    // water until both PTS clocks are known (0).
    uint32_t water;
    int64_t vpts = __atomic_load_n(&gVideoPTSms, __ATOMIC_ACQUIRE);
    int64_t apts = __atomic_load_n(&gAudioWritePTSms, __ATOMIC_ACQUIRE);
    if (vpts > 0 && apts > 0) {
        int64_t targetMs = (apts - vpts) + (int64_t)gJitterMs;
        if (targetMs < (int64_t)IVCAM_JITTER_MS_MIN) targetMs = (int64_t)IVCAM_JITTER_MS_MIN;
        if (targetMs > (int64_t)IVCAM_JITTER_MS_MAX) targetMs = (int64_t)IVCAM_JITTER_MS_MAX;
        water = (uint32_t)((uint64_t)targetMs * gCtx.tgtRate / 1000ull) * tgtCh;
        IVCAMAtomicStore32(&gCtx.targetWaterSamples, water);
    } else {
        water = IVCAMAtomicLoad32(&gCtx.targetWaterSamples);
    }

    uint32_t w = IVCAMAtomicLoad32(&gCtx.writeIdx);
    uint32_t r = gConsumerRead;
    uint32_t avail = w - r;

    // Jitter buffer priming: hold until the buffer first reaches the target water level, so
    // replacement starts with a cushion. While priming, if OBS audio is already arriving (the
    // producer has fed since latch -> avail>0), MUTE the real mic so no external sound leaks into
    // the recording before OBS takes over. If avail==0 (nothing streaming) fall open to the real
    // mic, so a no-stream recording keeps working (fail-open).
    if (!gCtx.primed) {
        if (water == 0 || avail < water) {
            // Priming: mute the real mic if OBS audio is already arriving (avail>0) OR OBS is
            // streaming (muteLeak) — the latter covers the startup window before the first PCM
            // lands, so the ~5s of external sound at record start is silenced instead of recorded.
            if (avail > 0 || muteLeak) IVCAMMediaActiveMuteRT(ioData);
            return status;
        }
        gCtx.primed = 1;
    }

    // Keep the buffer CLOSE to the water level so audio latency ≈ the sync target. AGGRESSIVE
    // one-shot catch-up: drop ALL excess above water in a single step (not capped to one render),
    // so a backlog that formed before recording started — or after a stall/relatch — is discarded
    // immediately instead of draining slowly while the producer keeps writing. O(1) (just advances
    // readIdx, consumer-owned, SPSC-safe); the discarded span is one forward skip, not a lingering
    // lag. In steady state avail sits near water so excess is tiny.
    if (water > 0 && avail > water + (water >> 2)) {
        uint32_t excess = avail - water;   // drop the WHOLE backlog down to water, in one shot
        excess -= excess % tgtCh;
        if (excess > 0) {
            r += excess;
            avail -= excess;
            IVCAMAtomicAdd64(&gCtx.trimDrops, excess);
        }
    }

    uint32_t take = avail < need ? avail : need;
    take -= take % tgtCh;  // whole frames (avail is already frame-aligned)

    // Copy `take` samples from the ring into scratch (<=2 chunks on wrap).
    if (take > 0) {
        uint32_t pos = r & IVCAM_RING_MASK;
        uint32_t first = IVCAM_RING_SAMPLES - pos;
        if (first > take) first = take;
        memcpy(gCtx.scratch, &gCtx.buf[pos], (size_t)first * sizeof(int16_t));
        if (take > first) {
            memcpy(gCtx.scratch + first, &gCtx.buf[0], (size_t)(take - first) * sizeof(int16_t));
        }
        r += take;
    }
    gConsumerRead = r;
    IVCAMAtomicStore32(&gCtx.readIdx, r);

    uint32_t takeFrames = take / tgtCh;
    uint32_t fadeFrames = inNumberFrames - takeFrames;

    // Fill the fade region so we always emit the full render (the tail otherwise
    // still holds real mic audio from the original render and would leak through).
    if (fadeFrames > 0) {
        IVCAMAtomicAdd64(&gCtx.underruns, 1);
        int16_t seed[2];
        if (takeFrames > 0) {
            for (uint32_t c = 0; c < tgtCh; c++) seed[c] = gCtx.scratch[(takeFrames - 1) * tgtCh + c];
            gCtx.starveRun = 0;
        } else {
            for (uint32_t c = 0; c < tgtCh; c++) seed[c] = gCtx.lastOut[c];
            gCtx.starveRun++;
        }
        // Linear gain ramp from the last real sample toward silence -> click-free.
        for (uint32_t f = 0; f < fadeFrames; f++) {
            double gain = 1.0 - (double)(f + 1) / (double)fadeFrames;
            for (uint32_t c = 0; c < tgtCh; c++) {
                gCtx.scratch[(takeFrames + f) * tgtCh + c] = (int16_t)((double)seed[c] * gain);
            }
        }
        // Sustained starvation (bridge really gone) -> un-prime so we fall open to the
        // real mic on the next call instead of emitting endless silence.
        if (gCtx.starveRun > 50) {
            gCtx.primed = 0;
            gCtx.starveRun = 0;
        }
    } else {
        gCtx.starveRun = 0;
    }

    // Remember the last emitted sample per channel to seed the next fade.
    for (uint32_t c = 0; c < tgtCh; c++) {
        gCtx.lastOut[c] = gCtx.scratch[(inNumberFrames - 1) * tgtCh + c];
    }

    // Write scratch (target-format interleaved int16) into ioData, clamped to each
    // buffer's byte size. Pure fixed-point / float scaling; no allocation.
    if (gCtx.tgtIsFloat) {
        if (nonInterleaved) {
            for (uint32_t ch = 0; ch < tgtCh; ch++) {
                if (!ioData->mBuffers[ch].mData) { return status; }
                float *out = (float *)ioData->mBuffers[ch].mData;
                uint32_t wf = ioData->mBuffers[ch].mDataByteSize / (uint32_t)sizeof(float);
                if (wf > inNumberFrames) wf = inNumberFrames;
                for (uint32_t i = 0; i < wf; i++) {
                    out[i] = (float)gCtx.scratch[i * tgtCh + ch] / 32768.0f;
                }
                ioData->mBuffers[ch].mDataByteSize = wf * (uint32_t)sizeof(float);
            }
        } else {
            float *out = (float *)ioData->mBuffers[0].mData;
            uint32_t ws = ioData->mBuffers[0].mDataByteSize / (uint32_t)sizeof(float);
            if (ws > need) ws = need;
            for (uint32_t i = 0; i < ws; i++) {
                out[i] = (float)gCtx.scratch[i] / 32768.0f;
            }
            ioData->mBuffers[0].mDataByteSize = ws * (uint32_t)sizeof(float);
        }
    } else {
        if (nonInterleaved) {
            for (uint32_t ch = 0; ch < tgtCh; ch++) {
                if (!ioData->mBuffers[ch].mData) { return status; }
                int16_t *out = (int16_t *)ioData->mBuffers[ch].mData;
                uint32_t wf = ioData->mBuffers[ch].mDataByteSize / (uint32_t)sizeof(int16_t);
                if (wf > inNumberFrames) wf = inNumberFrames;
                for (uint32_t i = 0; i < wf; i++) {
                    out[i] = gCtx.scratch[i * tgtCh + ch];
                }
                ioData->mBuffers[ch].mDataByteSize = wf * (uint32_t)sizeof(int16_t);
            }
        } else {
            uint32_t bytes = need * (uint32_t)sizeof(int16_t);
            if (bytes > ioData->mBuffers[0].mDataByteSize) bytes = ioData->mBuffers[0].mDataByteSize;
            memcpy(ioData->mBuffers[0].mData, gCtx.scratch, bytes);
            ioData->mBuffers[0].mDataByteSize = bytes;
        }
    }

    IVCAMAtomicAdd64(&gCtx.replaced, 1);
    IVCAMAtomicStore64(&gCtx.lastRenderUs, (t0 * (uint64_t)gCtx.tbNumer / (uint64_t)gCtx.tbDenom) / 1000ull);

    uint64_t t1 = mach_absolute_time();
    uint64_t elapsedNs = (t1 - t0) * (uint64_t)gCtx.tbNumer / (uint64_t)gCtx.tbDenom;
    __atomic_store_n(&gCtx.renderNsLast, elapsedNs, __ATOMIC_RELAXED);
    if (elapsedNs > __atomic_load_n(&gCtx.renderNsMax, __ATOMIC_RELAXED)) {
        __atomic_store_n(&gCtx.renderNsMax, elapsedNs, __ATOMIC_RELAXED);
    }
    uint64_t periodNs = (uint64_t)inNumberFrames * 1000000000ull / (gCtx.tgtRate ? gCtx.tgtRate : 48000u);
    if (elapsedNs > periodNs) IVCAMAtomicAdd64(&gCtx.periodOverruns, 1);

    return status;
}

#pragma mark - Background telemetry + maintenance (dispatch timer)

static void IVCAMMediaActiveBackgroundTick(void) {
    IVCAMMediaActiveReloadPrefs(NO);

    if (__atomic_load_n(&gCtx.latchLogPending, __ATOMIC_RELAXED)) {
        __atomic_store_n(&gCtx.latchLogPending, 0, __ATOMIC_RELAXED);
        IVCAMMediaActiveLog(@"MEDIA_ACTIVE_LATCH unit=%p bus=%u rate=%u ch=%u float=%u bits=%u nonInterleaved=%u water=%u",
                            gCtx.consumerUnit, gCtx.consumerBus, gCtx.tgtRate, gCtx.tgtChannels,
                            gCtx.tgtIsFloat, gCtx.tgtBits, gCtx.tgtNonInterleaved,
                            IVCAMAtomicLoad32(&gCtx.targetWaterSamples));
    }

    // Re-latch: if the latched unit has gone idle (torn down / app switched), release
    // the latch so a fresh unit can take over on its next render.
    void *consumer = __atomic_load_n(&gCtx.consumerUnit, __ATOMIC_ACQUIRE);
    if (consumer != NULL) {
        uint64_t nowUs = IVCAMNowUs();
        uint64_t lastUs = IVCAMAtomicLoad64(&gCtx.lastRenderUs);
        if (lastUs != 0 && nowUs > lastUs && (nowUs - lastUs) > IVCAM_RELATCH_IDLE_US) {
            IVCAMAtomicStore32(&gCtx.formatReady, 0);
            __atomic_store_n(&gCtx.consumerUnit, NULL, __ATOMIC_RELEASE);
            IVCAMAtomicStore64(&gCtx.lastRenderUs, 0);
            IVCAMMediaActiveLog(@"MEDIA_ACTIVE_RELATCH released idle consumer unit");
        }
    }

    uint32_t w = IVCAMAtomicLoad32(&gCtx.writeIdx);
    uint32_t r = IVCAMAtomicLoad32(&gCtx.readIdx);
    uint32_t fill = w - r;
    uint32_t fillMs = (gCtx.tgtRate && gCtx.tgtChannels)
        ? (uint32_t)((uint64_t)fill * 1000ull / ((uint64_t)gCtx.tgtRate * gCtx.tgtChannels)) : 0;
    IVCAMMediaActiveLog(@"MEDIA_ACTIVE_STATS render=%llu replaced=%llu underruns=%llu trimDrops=%llu overflowDrops=%llu parked=%llu unsupported=%llu fill=%u fillMs=%u primed=%u",
                        IVCAMAtomicLoad64(&gCtx.renderCalls),
                        IVCAMAtomicLoad64(&gCtx.replaced),
                        IVCAMAtomicLoad64(&gCtx.underruns),
                        IVCAMAtomicLoad64(&gCtx.trimDrops),
                        IVCAMAtomicLoad64(&gCtx.overflowDrops),
                        IVCAMAtomicLoad64(&gCtx.parkedFrames),
                        IVCAMAtomicLoad64(&gCtx.unsupported),
                        fill, fillMs, gCtx.primed);
    // A/V sync telemetry: the PTS gap (newest audio − displayed video) is the dynamic part of the
    // buffer target; targetWater(ms) is what the consumer is actually holding. If audio still
    // leads/lags in steady state, tune the base JitterMs pref (live).
    {
        int64_t vpts = __atomic_load_n(&gVideoPTSms, __ATOMIC_ACQUIRE);
        int64_t apts = __atomic_load_n(&gAudioWritePTSms, __ATOMIC_ACQUIRE);
        uint32_t tw = IVCAMAtomicLoad32(&gCtx.targetWaterSamples);
        uint32_t twMs = (gCtx.tgtRate && gCtx.tgtChannels)
            ? (uint32_t)((uint64_t)tw * 1000ull / ((uint64_t)gCtx.tgtRate * gCtx.tgtChannels)) : 0;
        IVCAMMediaActiveLog(@"MEDIA_ACTIVE_SYNC videoPTS=%lld audioPTS=%lld leadMs=%lld jitterMs=%u targetWaterMs=%u",
                            vpts, apts, apts - vpts, gJitterMs, twMs);
    }
    IVCAMMediaActiveLog(@"MEDIA_ACTIVE_RENDER_TIME lastNs=%llu maxNs=%llu periodOverruns=%llu",
                        __atomic_load_n(&gCtx.renderNsLast, __ATOMIC_RELAXED),
                        __atomic_load_n(&gCtx.renderNsMax, __ATOMIC_RELAXED),
                        IVCAMAtomicLoad64(&gCtx.periodOverruns));
}

static void IVCAMMediaActiveStartBackground(void) {
    static dispatch_source_t timer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t queue = dispatch_queue_create("com.iosvcam.audiobridge.media-active.telemetry",
                                                        DISPATCH_QUEUE_SERIAL);
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                                  2 * NSEC_PER_SEC, (uint64_t)(0.25 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            @autoreleasepool {
                IVCAMMediaActiveBackgroundTick();
            }
        });
        dispatch_resume(timer);
    });
}

#pragma mark - Constructor

%ctor {
    @autoreleasepool {
#if VCAM_AUDIO_DISABLE
        // Video-only A/B build: the audio subsystem installs NOTHING (no AudioUnitRender hook, no
        // producer, no ring). Isolates whether the audio subsystem's render load / IOSurface
        // pressure is what halves the recording fps. The PushPCM/SetVideoPTS/SetOBSStreaming
        // symbols still link (called by the video path) but are inert no-ops here.
        return;
#endif
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *processName = [[NSProcessInfo processInfo] processName] ?: @"";
        NSString *executablePath = [[NSProcessInfo processInfo] arguments].firstObject ?: @"";
        BOOL targetProcess = [bundleID isEqualToString:IVCAM_MEDIA_ACTIVE_TARGET_BUNDLE] ||
                             [processName isEqualToString:IVCAM_MEDIA_ACTIVE_TARGET_PROCESS];

        IVCAMMediaActiveLog(@"MEDIA_ACTIVE_LOADED bundle=%@ process=%@ executable=%@ uid=%d euid=%d target=%d",
                            bundleID, processName, executablePath, getuid(), geteuid(), targetProcess);

        IVCAMMediaActiveLog(@"MEDIA_ACTIVE_PATHS tweakinject=%d autopatches=%d pkgmirror=%d disabled=%d",
                            IVCAMMediaActivePathExists(@"/usr/lib/TweakInject"),
                            IVCAMMediaActivePathExists(@"/usr/lib/DynamicPatches/AutoPatches.dylib"),
                            IVCAMMediaActivePathExists(@"/var/mobile/Library/pkgmirror/Library/MobileSubstrate/DynamicLibraries"),
                            IVCAMMediaActivePathExists(IVCAM_MEDIA_ACTIVE_DISABLE_FLAG));

        if (IVCAMMediaActivePathExists(IVCAM_MEDIA_ACTIVE_DISABLE_FLAG)) {
            IVCAMMediaActiveLog(@"MEDIA_ACTIVE_DISABLED by file flag");
            return;
        }

        // A/B fps diagnostic: if /var/mobile/Media/vcam_noaudio exists, the audio subsystem does
        // NOT install its AudioUnitRender hook / producer, so mediaserverd runs video-only. Lets us
        // test whether the audio hook drags recording from 30fps to 15fps — toggle over SSH (Media
        // is a path mediaserverd's sandbox CAN stat, unlike /var/tmp), relaunch the camera app.
        if (IVCAMMediaActivePathExists(@"/var/mobile/Media/vcam_noaudio")) {
            IVCAMMediaActiveLog(@"MEDIA_ACTIVE_DISABLED by /var/mobile/Media/vcam_noaudio (video-only fps test)");
            return;
        }

        if (!targetProcess) {
            IVCAMMediaActiveLog(@"MEDIA_ACTIVE_INACTIVE not media target");
            return;
        }

        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        gCtx.tbNumer = tb.numer ? tb.numer : 1;
        gCtx.tbDenom = tb.denom ? tb.denom : 1;

        IVCAMMediaActiveReloadPrefs(YES);
        IVCAMMediaActiveStartBackground();
        // The producer thread runs for the process lifetime and idles while disabled,
        // so a later CFPreferences enable can reconnect without respawning it.
        IVCAMMediaActiveStartProducer();

        MSHookFunction((void *)AudioUnitRender, (void *)IVCAMMediaActiveAudioUnitRender,
                       (void **)&gOriginalAudioUnitRender);
        IVCAMMediaActiveLog(@"MEDIA_ACTIVE_READY AudioUnitRender hook installed; lock-free ring + jitter buffer active");
    }
}

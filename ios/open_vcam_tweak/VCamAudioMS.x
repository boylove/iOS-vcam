// ---------------------------------------------------------------------------
// OpenVCam — audio subsystem (GLOBAL, mediaserverd). BROADCAST + LOCK-FREE.
//
// Rewritten (0.6.40) after 0.6.39 caused a continuous HAL overload
// (ClientHALIODurationExceededBudget ~22x/s) that froze stock-Camera recording.
// Device syslog root-caused three problems, all fixed here:
//   1. 0.6.39 put an os_unfair_lock on the CoreAudio RENDER thread. Locks on the
//      audio RT thread are a known overload source (the proven-good 0.5.x-0.6.35
//      ring was lock-free). This FIFO is now LOCK-FREE: single-writer producer +
//      CAS-claim consumers, no lock anywhere the render thread touches.
//   2. OBS audio was 44100 Hz but the mic units are 48000 Hz, so the exact-rate
//      consumer never injected and the producer flooded the ring. The producer
//      now RESAMPLES to the render unit's cached rate, so the consumer always
//      matches and actually drains.
//   3. The producer decoded + pushed OBS audio continuously even when NO mic was
//      capturing (preview), loading mediaserverd for nothing. Audio work is now
//      IDLE-GATED: the AAC decoder skips decoding (via IVCAMAudioWantsDecode) and
//      the producer parks until a mic-input render has occurred recently.
//
// Model is still BROADCAST: ANY mic-input (bus 1) render pops directly from ONE
// shared FIFO — no latched consumer unit, no stealing, no priming. Whichever unit
// actually renders the mic gets OBS audio; naturally multi-app since one app
// records at a time. Producer path unchanged in spirit (RTMP msg_type 8 ->
// VCamAACDecoder -> IVCAMMediaActivePushPCM).
//
// Fail-open everywhere; the one mic-leak guard mutes (not real mic) only during a
// momentary underrun WHILE OBS audio is actively flowing. A video-only stream or
// the startup window falls open to the real mic.
//
// Recovery if anything wedges: remove the package + `killall mediaserverd`.
// ---------------------------------------------------------------------------
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <substrate.h>
#import <dispatch/dispatch.h>
#import <mach/mach_time.h>
#import <math.h>
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

// FIFO ring holds resampled (target-rate) interleaved int16. 1<<17 = 131072
// samples = ~1.37 s stereo @ 48 kHz, above the FIFO cap below.
#define IVCAM_RING_SAMPLES (1u << 17)
#define IVCAM_RING_MASK    (IVCAM_RING_SAMPLES - 1u)

// Largest render serviced on the stack scratch; larger renders fall open.
#define IVCAM_MAX_RENDER_FRAMES 8192u

// Producer resample output scratch (single producer thread; 8192 frames stereo).
#define IVCAM_PROD_OUT_SAMPLES 16384u

// FIFO high-water cap (~1 s of the freshest audio); bounds latency if a consumer
// stalls. In steady state the consumer drains each render so this never trips.
#define IVCAM_FIFO_CAP_MS 1000u

// Mic-leak guard window: an underrun mutes (no real-mic leak) only if OBS audio
// was produced within this window (a live stream's momentary gap). Older/never ->
// fall open to the real mic.
#define IVCAM_RECENT_AUDIO_US 500000ull

// Idle gate: OBS audio is decoded + pushed only while a mic-input render has
// occurred within this window. No mic capturing (preview) -> no decode, no push,
// no HAL load. Generous so active recording never starves.
#define IVCAM_ACTIVE_WINDOW_US 1000000ull

// Format-probe throttle: AudioUnitGetProperty is not cheap on the render thread;
// probing every render across mediaserverd's mic units blows the HAL budget. Probe
// at most once per this interval, cache the packed format, reuse it.
#define IVCAM_FMT_PROBE_US 200000ull

// ---------------------------------------------------------------------------
// Shared state — all cross-thread access is via __atomic (LOCK-FREE).
// ---------------------------------------------------------------------------
static int16_t gRing[IVCAM_RING_SAMPLES];  // target-rate interleaved int16
static uint32_t gReadIdx = 0;   // advanced by consumers via CAS (+ producer reset on fmt change)
static uint32_t gWriteIdx = 0;  // single writer: the producer

// FIFO format published by the producer: rate == the consumer's cached unit rate
// (producer resamples to it), channels == the OBS source channels.
static uint32_t gFifoRate = 0;
static uint32_t gFifoChannels = 0;

// Cached render-unit format, packed atomically: bits 0-17 rate, 18-19 channels,
// 20 isFloat, 21 nonInterleaved; 0 = not yet probed.
static volatile uint32_t gFmtPacked = 0;
static volatile uint64_t gLastProbeUs = 0;
static volatile uint64_t gLastRenderUs = 0;  // last mic-input (bus 1) render, for the idle gate

static volatile int32_t  gEnabled = 1;
static volatile int32_t  gOBSStreaming = 0;
static volatile uint64_t gLastProducedUs = 0;

static volatile int64_t  gVideoPTSms = 0;       // telemetry only
static volatile int64_t  gAudioWritePTSms = 0;

static volatile uint64_t gRenderCalls = 0;
static volatile uint64_t gReplaced = 0;
static volatile uint64_t gUnderruns = 0;
static volatile uint64_t gMuted = 0;
static volatile uint64_t gOverflowDrops = 0;
static volatile uint64_t gUnsupported = 0;

static uint32_t gTbNumer = 1;
static uint32_t gTbDenom = 1;

// Producer resample scratch (single producer thread -> no sharing).
static int16_t gProducerOut[IVCAM_PROD_OUT_SAMPLES];

static OSStatus (*gOriginalAudioUnitRender)(AudioUnit inUnit,
                                            AudioUnitRenderActionFlags *ioActionFlags,
                                            const AudioTimeStamp *inTimeStamp,
                                            UInt32 inOutputBusNumber,
                                            UInt32 inNumberFrames,
                                            AudioBufferList *ioData) = NULL;

static inline uint32_t IVCAMPackFmt(uint32_t rate, uint32_t ch, uint32_t isFloat, uint32_t ni) {
    return (rate & 0x3FFFFu) | ((ch & 0x3u) << 18) | ((isFloat & 1u) << 20) | ((ni & 1u) << 21);
}

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
    if (attrs && [attrs[NSFileSize] unsignedLongLongValue] > 131072) [fm removeItemAtPath:path error:nil];
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

static void IVCAMAudioLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *path in IVCAMAudioLogPaths()) if (IVCAMAudioAppendLog(path, data)) break;
    const char *utf8 = [message UTF8String];
    if (utf8) syslog(LOG_NOTICE, "[iOSVCAMAudioBridgeMediaActive] %s", utf8);
    NSLog(@"[iOSVCAMAudioBridgeMediaActive] %@", message);
}

// ---------------------------------------------------------------------------
// Preferences (off-render-thread only) — runtime enable/disable gate.
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
// Linear resampler (producer thread; off-RT). Resamples one interleaved block.
// ---------------------------------------------------------------------------
static uint32_t IVCAMResampleLinear(const int16_t *in, uint32_t inFrames, uint32_t ch,
                                    uint32_t srcRate, uint32_t tgtRate,
                                    int16_t *out, uint32_t outCapFrames) {
    if (inFrames < 2 || ch == 0) return 0;
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

// ---------------------------------------------------------------------------
// Idle gate — the AAC decoder calls this to skip decoding when no mic is active.
// ---------------------------------------------------------------------------
int IVCAMAudioWantsDecode(void) {
    if (!__atomic_load_n(&gEnabled, __ATOMIC_ACQUIRE)) return 0;
    uint64_t last = __atomic_load_n(&gLastRenderUs, __ATOMIC_ACQUIRE);
    if (last == 0) return 0;                          // no mic render ever -> idle
    uint64_t now = IVCAMNowUs();
    return (now >= last && (now - last) < IVCAM_ACTIVE_WINDOW_US) ? 1 : 0;
}

// ---------------------------------------------------------------------------
// Producer — resample OBS PCM to the render unit's rate and append to the FIFO.
// Off-RT only (RTMP/AAC thread). LOCK-FREE single writer; parks until a consumer
// has cached its format (so no flood while idle).
// ---------------------------------------------------------------------------
void IVCAMMediaActivePushPCM(const int16_t *pcm, uint32_t srcFrames,
                             uint32_t srcRate, uint32_t srcCh, int64_t ptsMs) {
    if (!pcm || srcFrames == 0 || !(srcCh == 1 || srcCh == 2)) return;
    if (srcRate == 0 || srcRate > 192000) return;
    if (!__atomic_load_n(&gEnabled, __ATOMIC_ACQUIRE)) return;

    if (ptsMs > 0)
        __atomic_store_n(&gAudioWritePTSms, ptsMs + (int64_t)srcFrames * 1000 / (int64_t)srcRate, __ATOMIC_RELEASE);

    // Park until a mic-input render has cached its format: gives the target rate to
    // resample to AND keeps the ring empty while no app is capturing (no flood).
    uint32_t packed = __atomic_load_n(&gFmtPacked, __ATOMIC_ACQUIRE);
    uint32_t tgtRate = packed & 0x3FFFFu;
    if (packed == 0 || tgtRate == 0) return;

    // Resample source rate -> the render unit's rate (channels unchanged; mapped at pop).
    const int16_t *finalPcm;
    uint32_t finalFrames;
    if (srcRate == tgtRate) {
        finalPcm = pcm;
        finalFrames = srcFrames;
    } else {
        finalFrames = IVCAMResampleLinear(pcm, srcFrames, srcCh, srcRate, tgtRate,
                                          gProducerOut, IVCAM_PROD_OUT_SAMPLES / srcCh);
        if (finalFrames == 0) return;
        finalPcm = gProducerOut;
    }

    uint32_t n = finalFrames * srcCh;
    if (n == 0 || n > IVCAM_RING_SAMPLES) return;

    // Format change -> discard pending FIFO (benign race with consumer CAS: worst
    // case a consumer's claim fails and it falls open for one render).
    if (__atomic_load_n(&gFifoRate, __ATOMIC_RELAXED) != tgtRate ||
        __atomic_load_n(&gFifoChannels, __ATOMIC_RELAXED) != srcCh) {
        __atomic_store_n(&gReadIdx, __atomic_load_n(&gWriteIdx, __ATOMIC_ACQUIRE), __ATOMIC_RELEASE);
        __atomic_store_n(&gFifoRate, tgtRate, __ATOMIC_RELEASE);
        __atomic_store_n(&gFifoChannels, srcCh, __ATOMIC_RELEASE);
    }

    // LOCK-FREE write (single producer). Drop the NEW payload if it would exceed the
    // cap; the producer never advances readIdx (only consumers do), so no CAS needed.
    uint32_t w = __atomic_load_n(&gWriteIdx, __ATOMIC_RELAXED);
    uint32_t r = __atomic_load_n(&gReadIdx, __ATOMIC_ACQUIRE);
    uint32_t used = w - r;
    uint32_t cap = (uint32_t)((uint64_t)IVCAM_FIFO_CAP_MS * tgtRate / 1000ull) * srcCh;
    if (cap > IVCAM_RING_SAMPLES) cap = IVCAM_RING_SAMPLES;
    if (used + n > cap) {
        __atomic_add_fetch(&gOverflowDrops, n, __ATOMIC_RELAXED);
        return;
    }
    uint32_t pos = w & IVCAM_RING_MASK;
    uint32_t first = IVCAM_RING_SAMPLES - pos;
    if (first > n) first = n;
    memcpy(&gRing[pos], finalPcm, (size_t)first * sizeof(int16_t));
    if (n > first) memcpy(&gRing[0], finalPcm + first, (size_t)(n - first) * sizeof(int16_t));
    __atomic_store_n(&gWriteIdx, w + n, __ATOMIC_RELEASE);

    __atomic_store_n(&gLastProducedUs, IVCAMNowUs(), __ATOMIC_RELEASE);
}

void IVCAMSetVideoPTS(int64_t ptsMs) { __atomic_store_n(&gVideoPTSms, ptsMs, __ATOMIC_RELEASE); }
void IVCAMSetOBSStreaming(int on) { __atomic_store_n(&gOBSStreaming, on ? 1 : 0, __ATOMIC_RELEASE); }

// ---------------------------------------------------------------------------
// Render hook (render thread; real-time, LOCK-FREE)
// ---------------------------------------------------------------------------

// Read source frame `frame` (relative to claimed read index `r`), output channel
// `c`, directly from the ring with channel mapping. No scratch buffer — reading
// straight from gRing keeps the render function's stack tiny (a 32 KiB stack
// scratch here overflowed the capture-graph source-node-start render thread ->
// "capture graph source nodes start" timeout -> mediaserverd reset, the 0.6.39/40
// regression). Frames never straddle the ring wrap (RING is a multiple of srcCh),
// so a frame's srcCh samples are contiguous; the per-frame index is masked.
static inline int16_t IVCAMRingMapSample(uint32_t r, uint32_t frame, uint32_t c,
                                         uint32_t srcCh, uint32_t targetCh) {
    uint32_t base = (r + frame * srcCh) & IVCAM_RING_MASK;
    if (srcCh == targetCh) return gRing[(base + c) & IVCAM_RING_MASK];
    if (srcCh == 1) return gRing[base];                                 // mono -> stereo (dup)
    return (int16_t)(((int32_t)gRing[base] + (int32_t)gRing[(base + 1) & IVCAM_RING_MASK]) / 2);  // stereo -> mono
}

static inline void IVCAMMuteRT(AudioBufferList *ioData) {
    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++)
        if (ioData->mBuffers[i].mData)
            memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
}

// Fill ioData with OBS audio popped from the FIFO. Returns YES if replaced, NO on
// unsupported format / rate mismatch / underrun (caller mutes or falls open).
// RT-safe: LOCK-FREE CAS claim then memcpy + arithmetic. The only CoreAudio call
// is the format probe, rate-limited to ~IVCAM_FMT_PROBE_US (never per render).
static BOOL IVCAMFillFromFifo(AudioUnit inUnit, UInt32 bus,
                              UInt32 inNumberFrames, AudioBufferList *ioData) {
    if (inNumberFrames == 0 || inNumberFrames > IVCAM_MAX_RENDER_FRAMES) return NO;

    // Render-unit format from the rate-limited cache. Probe FAST while bootstrapping
    // (packed==0, retry a failed probe within ~200 ms) but SLOWLY once cached (~1 s,
    // just to catch a format switch) — the format is fixed for a session, so this
    // keeps AudioUnitGetProperty off the render hot path in steady state.
    uint64_t nowUs = IVCAMNowUs();
    uint32_t packed = __atomic_load_n(&gFmtPacked, __ATOMIC_ACQUIRE);
    uint64_t lastProbe = __atomic_load_n(&gLastProbeUs, __ATOMIC_RELAXED);
    uint64_t probeGap = (packed == 0) ? IVCAM_FMT_PROBE_US : 1000000ull;
    if (nowUs - lastProbe > probeGap) {
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
    if (packed == 0) return NO;

    uint32_t fmtRate = packed & 0x3FFFFu;
    UInt32 targetCh = (packed >> 18) & 0x3u;
    BOOL isFloat = ((packed >> 20) & 1u) != 0;
    BOOL nonInterleaved = ((packed >> 21) & 1u) != 0;
    if (!(targetCh == 1 || targetCh == 2)) return NO;

    // The producer resamples to the cached unit rate, so the FIFO rate should equal
    // this unit's rate. If not (just after a format switch), fall open.
    uint32_t fifoRate = __atomic_load_n(&gFifoRate, __ATOMIC_ACQUIRE);
    uint32_t srcCh = __atomic_load_n(&gFifoChannels, __ATOMIC_ACQUIRE);
    if (fifoRate == 0 || fifoRate != fmtRate || !(srcCh == 1 || srcCh == 2)) return NO;

    // Validate the buffer layout before consuming.
    if (nonInterleaved) {
        if (ioData->mNumberBuffers < targetCh) return NO;
        for (UInt32 ch = 0; ch < targetCh; ch++)
            if (!ioData->mBuffers[ch].mData) return NO;
    } else {
        if (ioData->mNumberBuffers < 1 || !ioData->mBuffers[0].mData) return NO;
    }

    // LOCK-FREE CAS claim of inNumberFrames*srcCh source samples.
    uint32_t needSrc = inNumberFrames * srcCh;
    uint32_t r = 0;
    BOOL claimed = NO;
    for (int tries = 0; tries < 8; tries++) {
        r = __atomic_load_n(&gReadIdx, __ATOMIC_ACQUIRE);
        uint32_t w = __atomic_load_n(&gWriteIdx, __ATOMIC_ACQUIRE);
        if (w - r < needSrc) break;   // underrun
        if (__atomic_compare_exchange_n(&gReadIdx, &r, r + needSrc, false,
                                        __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            claimed = YES;
            break;
        }
        // CAS reloaded r; retry
    }
    if (!claimed) {
        __atomic_add_fetch(&gUnderruns, 1, __ATOMIC_RELAXED);
        return NO;
    }

    // Fill ioData by reading the claimed span DIRECTLY from the ring (no scratch
    // buffer — a big stack array here overflowed the source-node-start render
    // thread). Safe against a producer wrap: it would need to write the whole ring
    // in the µs before these reads. Channel-map inline (int16/float, interleaved/non).
    if (isFloat) {
        if (nonInterleaved) {
            for (UInt32 ch = 0; ch < targetCh; ch++) {
                float *out = (float *)ioData->mBuffers[ch].mData;
                UInt32 wf = ioData->mBuffers[ch].mDataByteSize / (UInt32)sizeof(float);
                if (wf > inNumberFrames) wf = inNumberFrames;
                for (UInt32 i = 0; i < wf; i++)
                    out[i] = (float)IVCAMRingMapSample(r, i, ch, srcCh, targetCh) / 32768.0f;
                ioData->mBuffers[ch].mDataByteSize = wf * (UInt32)sizeof(float);
            }
        } else {
            float *out = (float *)ioData->mBuffers[0].mData;
            UInt32 wf = ioData->mBuffers[0].mDataByteSize / ((UInt32)sizeof(float) * targetCh);
            if (wf > inNumberFrames) wf = inNumberFrames;
            for (UInt32 i = 0; i < wf; i++)
                for (UInt32 c = 0; c < targetCh; c++)
                    out[i * targetCh + c] = (float)IVCAMRingMapSample(r, i, c, srcCh, targetCh) / 32768.0f;
            ioData->mBuffers[0].mDataByteSize = wf * targetCh * (UInt32)sizeof(float);
        }
    } else {
        if (nonInterleaved) {
            for (UInt32 ch = 0; ch < targetCh; ch++) {
                int16_t *out = (int16_t *)ioData->mBuffers[ch].mData;
                UInt32 wf = ioData->mBuffers[ch].mDataByteSize / (UInt32)sizeof(int16_t);
                if (wf > inNumberFrames) wf = inNumberFrames;
                for (UInt32 i = 0; i < wf; i++)
                    out[i] = IVCAMRingMapSample(r, i, ch, srcCh, targetCh);
                ioData->mBuffers[ch].mDataByteSize = wf * (UInt32)sizeof(int16_t);
            }
        } else {
            int16_t *out = (int16_t *)ioData->mBuffers[0].mData;
            UInt32 wf = ioData->mBuffers[0].mDataByteSize / ((UInt32)sizeof(int16_t) * targetCh);
            if (wf > inNumberFrames) wf = inNumberFrames;
            for (UInt32 i = 0; i < wf; i++)
                for (UInt32 c = 0; c < targetCh; c++)
                    out[i * targetCh + c] = IVCAMRingMapSample(r, i, c, srcCh, targetCh);
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

    if (inOutputBusNumber != 1) return status;       // only the mic-input element
    if (!__atomic_load_n(&gEnabled, __ATOMIC_ACQUIRE)) return status;

    // Signal the idle gate: a mic is actively capturing, so the producer may decode+push.
    __atomic_store_n(&gLastRenderUs, IVCAMNowUs(), __ATOMIC_RELEASE);
    __atomic_add_fetch(&gRenderCalls, 1, __ATOMIC_RELAXED);

    if (IVCAMFillFromFifo(inUnit, inOutputBusNumber, inNumberFrames, ioData)) {
        __atomic_add_fetch(&gReplaced, 1, __ATOMIC_RELAXED);
        return status;
    }

    // Couldn't supply OBS audio. Mic-leak guard: mute (not real mic) only if OBS
    // audio is actively flowing (a live stream's momentary gap). A video-only
    // stream or the startup window falls open to the real mic.
    if (__atomic_load_n(&gOBSStreaming, __ATOMIC_ACQUIRE)) {
        uint64_t lastProd = __atomic_load_n(&gLastProducedUs, __ATOMIC_ACQUIRE);
        uint64_t now = IVCAMNowUs();
        if (lastProd != 0 && now >= lastProd && (now - lastProd) < IVCAM_RECENT_AUDIO_US) {
            IVCAMMuteRT(ioData);
            __atomic_add_fetch(&gMuted, 1, __ATOMIC_RELAXED);
        }
    }
    return status;
}

// ---------------------------------------------------------------------------
// Background telemetry (dispatch timer, off-RT)
// ---------------------------------------------------------------------------
static void IVCAMAudioBackgroundTick(void) {
    IVCAMAudioReloadPrefs(NO);

    uint32_t w = __atomic_load_n(&gWriteIdx, __ATOMIC_ACQUIRE);
    uint32_t r = __atomic_load_n(&gReadIdx, __ATOMIC_ACQUIRE);
    uint32_t fill = w - r;
    uint32_t rate = __atomic_load_n(&gFifoRate, __ATOMIC_ACQUIRE);
    uint32_t ch = __atomic_load_n(&gFifoChannels, __ATOMIC_ACQUIRE);
    uint32_t fillMs = (rate && ch) ? (uint32_t)((uint64_t)fill * 1000ull / ((uint64_t)rate * ch)) : 0;
    uint32_t packed = __atomic_load_n(&gFmtPacked, __ATOMIC_ACQUIRE);
    int64_t vpts = __atomic_load_n(&gVideoPTSms, __ATOMIC_ACQUIRE);
    int64_t apts = __atomic_load_n(&gAudioWritePTSms, __ATOMIC_ACQUIRE);

    IVCAMAudioLog(@"AUDIO_STATS render=%llu replaced=%llu underruns=%llu muted=%llu overflow=%llu unsupported=%llu "
                   "fifoRate=%u fifoCh=%u fill=%u fillMs=%u obs=%d wantsDecode=%d leadMs=%lld "
                   "unitRate=%u unitCh=%u unitFloat=%u unitNI=%u",
                  __atomic_load_n(&gRenderCalls, __ATOMIC_RELAXED),
                  __atomic_load_n(&gReplaced, __ATOMIC_RELAXED),
                  __atomic_load_n(&gUnderruns, __ATOMIC_RELAXED),
                  __atomic_load_n(&gMuted, __ATOMIC_RELAXED),
                  __atomic_load_n(&gOverflowDrops, __ATOMIC_RELAXED),
                  __atomic_load_n(&gUnsupported, __ATOMIC_RELAXED),
                  rate, ch, fill, fillMs, __atomic_load_n(&gOBSStreaming, __ATOMIC_ACQUIRE),
                  IVCAMAudioWantsDecode(), (apts > 0 && vpts > 0) ? (apts - vpts) : 0,
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
        return;   // video-only A/B build: install nothing
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
        IVCAMAudioLog(@"AUDIO_READY lock-free broadcast hook installed (idle-gated, resample-to-unit)");
    }
}

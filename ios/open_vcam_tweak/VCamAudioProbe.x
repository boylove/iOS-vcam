// ---------------------------------------------------------------------------
// OpenVCam — mediaserverd audio-path PROBE (diagnostic, log-only).
//
// PURPOSE. Under RootHide, TikTok runs tweak-free, so OpenVCam's in-process mic
// hook never loads (device-proven: openvcam-roothide-blocks-tiktok-injection).
// The only way to replace TikTok's mic is inside mediaserverd — but TikTok's mic
// does NOT flow through the camera BufferWorks emit hook (0.6.47 proved it): it
// uses VoiceProcessingIO / the audio HAL, a different mediaserverd path. This
// probe finds WHICH mediaserverd audio function carries that PCM so we can inject
// OBS audio there like video, instead of guessing (blind audio fills crashed the
// capture graph and dropped fps before).
//
// SAFETY. Every hook is a strict PASS-THROUGH: it calls the original, and the only
// added work on the real-time audio thread is one atomic counter increment + a
// bounded (<=256 byte) non-zero peek. ALL logging is deferred to a background
// queue (never file I/O on the render thread). No buffer is ever modified, no
// AudioUnitGetProperty on the render thread (the HAL-overload trap), no locks.
// Default ON (log only); create /var/mobile/Media/vcam_noprobe to silence.
//
// READING THE LOG. While TikTok (RootHidden) records, watch for the function that
// starts firing at mic rate (hundreds of calls, climbing) carrying nz=1 PCM:
//   - AURender / AUProcess: clean signals (our code never calls them).
//   - ACFill: NOISY — our own VCamAACDecoder calls it (labeled ours=... by cv ptr);
//             a DIFFERENT cv appearing only during recording is TikTok's mic.
// If NONE fire for TikTok's mic, the path is the private HAL IOProc (deeper RE).
// ---------------------------------------------------------------------------
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <substrate.h>
#import <stdatomic.h>
#import <math.h>
#import <string.h>
#import <os/lock.h>
#import <mach/mach_time.h>

#import "VCamLog.h"
#import "VCamAudioSink.h"   // gVCamPCMSink, VCamPCMSink, IVCAMMediaActivePushPCM
#import "VCamConfig.h"      // [VCamConfig shared].replaceAudio — the 替换音频 toggle drives the inject

// TONE TEST gate (default OFF). Set by a background poller from the flag file, so it can be
// toggled without a reboot. When ON, the AUProcess hook overwrites the mono mic-effect buffers
// with a 440 Hz sine — proving this is the point that reaches TikTok's recorded mic (and that
// overwriting here is crash-safe) before the real OBS pipeline is wired.
static _Atomic int gMicTone = 0;
static _Atomic uint64_t gToneInjected = 0;

// OBS INJECT gate. Driven by the floating panel's 替换音频 switch ([VCamConfig shared].replaceAudio,
// default ON): the background poller mirrors that BOOL into this atomic so the RT AUProcess hook reads
// ONE atomic and never touches objc/the config lock on the audio thread. The legacy flag file
// /var/mobile/Media/vcam_micinject still force-enables it (a no-UI escape hatch / SSH test), OR'd in.
// When ON, the AUProcess hook overwrites the mono mic-effect buffers with OBS audio (resampled to 48 kHz
// mono). This is the RootHide-surviving TikTok mic replacement (the in-process hook never loads there).
static _Atomic int gMicInject = 0;
static _Atomic uint64_t gObsInjected = 0;

// --- OBS mic source: a lock-free ring (48 kHz mono int16) written by the shared AAC decoder, read by
// the AUProcess hook. CRITICAL (device-proven 0.6.57 telemetry): TikTok's mic runs through ~7 mono
// float32 effect units that ALL call AudioUnitProcess every render. A SINGLE shared read cursor gets
// scrambled by their jittering firing order -> the recorded unit hears a hum, not the voice (buf/averr
// telemetry swung ±80 ms). The 440 Hz tone stayed clean because it indexed each buffer by that unit's
// OWN mSampleTime. So OBS does the same: obsPos = base + mSampleTime, with a SEPARATE base PER UNIT, so
// each unit reads a CONTIGUOUS OBS stream (mSampleTime advances by exactly the period size per render) —
// the recorded unit is glitch-free no matter how many units we fill or in what order. A per-unit
// re-centre snaps the base back inside the ring on clock drift / gaps. Latency is a fixed ~gLatMs behind
// the write head (tunable via vcam_miclat; now that the audio is clean, lip-sync can be dialled there). ---
#define VCAM_RING 96000u    // 2 s @ 48 kHz mono
#define VCAM_LAT_MIN 1440u  //  30 ms @ 48 kHz — min headroom before an underrun re-centre
#define VCAM_LAT_MAX 19200u // 400 ms @ 48 kHz — max latency before an overrun/drift re-centre
static int16_t          gRing[VCAM_RING];
static _Atomic uint64_t gWritePos = 0;              // producer: total samples written
static os_unfair_lock   gReadLock = OS_UNFAIR_LOCK_INIT;
// Fixed target latency behind the write head (ms). Tunable live via /var/mobile/Media/vcam_miclat.
static _Atomic uint32_t gLatMs = 100;

// Per-unit OBS play mapping: obsPos = gUnitBase[i] + mSampleTime for the matching unit. One base per
// mic-effect unit gives each a contiguous read (see comment above). Small fixed table, scanned under
// gReadLock on the RT thread (a handful of entries — trivial).
//
// CROSS-SESSION RESET (device-proven bug: 1st TikTok clean, then stock Camera, then 2nd TikTok crackles).
// This table is NEVER cleared between capture sessions, and CoreAudio DESTROYS the VPIO effect units when
// recording stops and creates FRESH ones (new pointers) next time. Two failures compound: (a) dead unit
// pointers from old sessions accumulate and never match, filling the 16 slots; once full, every new unit
// evicts to slot 0 (the `gUnitCount<MICUNITS ? ... : 0` fallback), so a whole new session's ~7 units
// COLLAPSE onto ONE shared base — exactly the shared-cursor scramble the per-unit table exists to prevent
// -> crackle/hum. (b) even below capacity, a re-centre is per-unit so a stale base can linger. Fix: detect
// a NEW session by the gap in VCamMicRead calls (recording stops -> the mic units stop rendering for
// seconds; a real render cadence is ~<50 ms apart) and FLUSH the table at the start of each session, so
// every session rebuilds a clean, collision-free set of per-unit bases with no dead pointers.
#define VCAM_MICUNITS 16
static AudioUnit gUnitKey[VCAM_MICUNITS];
static int64_t   gUnitBase[VCAM_MICUNITS];
static int       gUnitCount = 0;
static uint64_t  gLastReadHost = 0;    // mach time of the previous VCamMicRead (session-gap detector)
// Health-log telemetry (written under gReadLock, read unlocked — approximate is fine).
static int              gDbgLatMs = 0;              // current playback latency behind the head (ms)
static int              gDbgUnits = 0;              // number of registered mic-effect units

// Producer (single AAC-decode thread, off the RT path): resample srcRate->48k, downmix ->mono, write ring.
// CRITICAL: the resample PHASE is carried across calls (gSrcPhase = fractional position into THIS block's
// input, plus a spilled last sample for interpolation across the block boundary). The old version reset
// pos=0 each block AND stopped at frames-1, so it dropped the last input sample of EVERY block and started
// each block at a fresh phase — a periodic discontinuity ≈ every (blockFrames/48k) that TikTok recorded as
// a "滋滋啦啦" crackle. Now the last sample of block N is the interpolation anchor for the first sample of
// block N+1, and the sub-sample phase persists, so the 48 kHz output is one continuous stream (like the
// clean IVCAMAudioPopForEmit path the stock Camera uses). gPrevSample/gHavePrev/gSrcPhase touched only on
// this single decode thread (no lock needed); the ring store is the release publish to the RT reader.
static double  gSrcPhase = 0.0;    // fractional read position within the current input block
static int16_t gPrevSample = 0;    // last mono sample of the previous block (cross-block interp anchor)
static int     gHavePrev = 0;
static void VCamMicPush(const int16_t *pcm, uint32_t frames, uint32_t rate, uint32_t ch) {
    if (!pcm || frames < 1 || !(ch == 1 || ch == 2) || rate == 0) return;
    int16_t tmp[8192];
    double step = (double)rate / 48000.0;
    uint32_t no = 0;
    uint64_t wp = atomic_load_explicit(&gWritePos, memory_order_relaxed);

    // Downmix helper (mono/stereo -> mono int16) for input index i in [-1 .. frames-1],
    // where -1 refers to the carried last sample of the previous block.
    #define VCAM_MONO_AT(i) ( (i) < 0 ? (int)gPrevSample \
                              : (ch == 1 ? (int)pcm[(i)] \
                                         : (((int)pcm[(i)*2] + (int)pcm[(i)*2+1]) / 2)) )

    // pos is measured from the previous block's last sample: pos in [0,1) interpolates prev->first,
    // pos in [k,k+1) interpolates input[k-1]->input[k]. On the very first block (no prev), start at
    // the first real sample so we don't fabricate a leading sample from silence.
    double pos = gHavePrev ? gSrcPhase : 1.0;
    double limit = (double)frames;   // last valid interpolation is input[frames-2]->input[frames-1] at pos<frames
    while (no < 8192 && pos < limit) {
        long k = (long)pos;               // integer part: interpolate (k-1) -> (k)
        double fr = pos - (double)k;
        int a = VCAM_MONO_AT(k - 1);
        int b = VCAM_MONO_AT(k);
        int v = (int)lround((double)a + ((double)b - (double)a) * fr);
        if (v > 32767) v = 32767; else if (v < -32768) v = -32768;
        tmp[no++] = (int16_t)v;
        pos += step;
    }
    // Carry the sub-sample phase into the next block (measured from this block's last sample) and
    // remember that last sample as the next block's interp anchor.
    gSrcPhase = pos - (double)frames;     // how far past the block end we landed (0..step)
    if (gSrcPhase < 0.0) gSrcPhase = 0.0;
    gPrevSample = (int16_t)VCAM_MONO_AT((long)frames - 1);
    gHavePrev = 1;
    #undef VCAM_MONO_AT

    for (uint32_t i = 0; i < no; i++) gRing[(wp + i) % VCAM_RING] = tmp[i];
    atomic_store_explicit(&gWritePos, wp + no, memory_order_release);
}

// Consumer (RT audio thread): fill dst[n] (float) for unit `u` at its mSampleTime `sampleTime`. Returns 1
// if primed. obsPos = per-unit base + sampleTime keeps EACH unit's read contiguous (mSampleTime advances
// by exactly n per render), so the recorded unit is glitch-free; the base is re-centred if it would under-
// or overrun the ring (clock drift between the OBS 48 kHz and the device 48 kHz, or a producer gap).
static int VCamMicRead(AudioUnit u, double sampleTime, float *dst, uint32_t n) {
    uint64_t wp = atomic_load_explicit(&gWritePos, memory_order_acquire);
    if (wp < (uint64_t)VCAM_LAT_MAX + n) return 0;                   // not primed yet
    uint32_t lat = atomic_load_explicit(&gLatMs, memory_order_relaxed) * 48u;
    if (lat < VCAM_LAT_MIN) lat = VCAM_LAT_MIN;
    else if (lat > VCAM_LAT_MAX - 2400u) lat = VCAM_LAT_MAX - 2400u; // keep headroom on both sides

    os_unfair_lock_lock(&gReadLock);

    // NEW-SESSION FLUSH: if the mic units haven't rendered for a while (recording stopped between apps),
    // the old units are gone and their pointers are stale — CoreAudio makes fresh ones next session. Clear
    // the whole table so the new session rebuilds clean per-unit bases with no dead entries and no
    // collapse-to-slot-0 (the 2nd-TikTok crackle). A live render cadence is tens of ms; use a 400 ms gap.
    {
        static _Atomic double toMs = 0.0;
        double m = atomic_load_explicit(&toMs, memory_order_relaxed);
        if (m == 0.0) { mach_timebase_info_data_t tb; mach_timebase_info(&tb);
                        m = (double)tb.numer / (double)tb.denom / 1.0e6;
                        atomic_store_explicit(&toMs, m, memory_order_relaxed); }
        uint64_t now = mach_absolute_time();
        if (gLastReadHost && now > gLastReadHost && (double)(now - gLastReadHost) * m > 400.0) {
            gUnitCount = 0;                                          // drop all stale units -> fresh session
            for (int i = 0; i < VCAM_MICUNITS; i++) gUnitKey[i] = NULL;
        }
        gLastReadHost = now;
    }

    int64_t st = (int64_t)sampleTime;
    int idx = -1;
    for (int i = 0; i < gUnitCount; i++) if (gUnitKey[i] == u) { idx = i; break; }
    if (idx < 0) {                                                   // first sight of this unit
        idx = (gUnitCount < VCAM_MICUNITS) ? gUnitCount++ : 0;       // (evict slot 0 only if ever full)
        gUnitKey[idx] = u;
        gUnitBase[idx] = (int64_t)(wp - lat) - st;                   // start ~lat behind the write head
    }
    int64_t obsPos = gUnitBase[idx] + st;
    if (obsPos + (int64_t)n > (int64_t)wp - (int64_t)VCAM_LAT_MIN || // caught the head (underrun)
        obsPos < (int64_t)wp - (int64_t)VCAM_LAT_MAX) {              // fell too far back (drift/gap)
        gUnitBase[idx] = (int64_t)(wp - lat) - st;                   // re-centre this unit
        obsPos = gUnitBase[idx] + st;
    }
    uint64_t rp = (uint64_t)obsPos;
    gDbgLatMs = (int)(((int64_t)wp - obsPos) / 48);
    gDbgUnits = gUnitCount;
    os_unfair_lock_unlock(&gReadLock);

    for (uint32_t i = 0; i < n; i++) dst[i] = (float)gRing[(rp + i) % VCAM_RING] / 32768.0f;
    return 1;
}

// Feed wrapper installed over gVCamPCMSink: keep the stock-Camera emit ring fed AND fill the mic ring.
static VCamPCMSink gPrevSink = NULL;
static void VCamMicFeedSink(const int16_t *pcm, uint32_t frames, uint32_t rate, uint32_t ch, int64_t pts) {
    if (gPrevSink) gPrevSink(pcm, frames, rate, ch, pts);
    VCamMicPush(pcm, frames, rate, ch);
}


static BOOL VCamProbeSilenced(void) {
    static int off = -1;
    if (off < 0) off = [[NSFileManager defaultManager]
                          fileExistsAtPath:@"/var/mobile/Media/vcam_noprobe"] ? 1 : 0;
    return off != 0;
}

// Cheap "is there any signal?" peek — first buffer, first <=256 bytes. Render-thread safe.
static int VCamBufNonZero(const AudioBufferList *io) {
    if (!io || io->mNumberBuffers == 0) return 0;
    const unsigned char *p = (const unsigned char *)io->mBuffers[0].mData;
    if (!p) return 0;
    UInt32 n = io->mBuffers[0].mDataByteSize;
    if (n > 256) n = 256;
    for (UInt32 i = 0; i < n; i++) if (p[i]) return 1;
    return 0;
}

// Defer the actual log off the render thread (rare: 1 in 500 calls).
static void VCamProbeLog(NSString *msg) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ VCamLog(@"%@", msg); });
}

// Render a CoreAudio 4-char-code (e.g. 'auou','vpio') as text. The constants are host-int;
// swap to big-endian so the bytes read in natural order.
static NSString *VCamFourCC(UInt32 c) {
    union { UInt32 u; unsigned char b[4]; } x;
    x.u = CFSwapInt32HostToBig(c);
    return [[NSString alloc] initWithBytes:x.b length:4 encoding:NSASCIIStringEncoding] ?: @"????";
}

// ---- AudioComponentInstanceNew: logs each audio unit's TYPE as it is created, so the
// AUProcess/AURender unit pointers above can be mapped to a role (VoiceProcessingIO = the
// mic IO, 'aufx' = effect, 'aumx' = mixer, ...). Called on the setup thread (not the RT
// audio thread), so the description fetch + log here are safe. ----
static OSStatus (*origACIN)(AudioComponent, AudioComponentInstance *);
static OSStatus probeACIN(AudioComponent comp, AudioComponentInstance *out) {
    OSStatus s = origACIN(comp, out);
    if (!VCamProbeSilenced() && s == noErr && out && *out) {
        AudioComponentDescription d; memset(&d, 0, sizeof(d));
        OSStatus g = AudioComponentGetDescription(comp, &d);
        VCamProbeLog([NSString stringWithFormat:
            @"probe NEWUNIT inst=%p type=%@ sub=%@ mfr=%@ (g=%d)",
            (void *)*out, VCamFourCC(d.componentType), VCamFourCC(d.componentSubType),
            VCamFourCC(d.componentManufacturer), (int)g]);
    }
    return s;
}

// ---- AudioUnitRender ----
static OSStatus (*origAUR)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                           UInt32, UInt32, AudioBufferList *);
static OSStatus probeAUR(AudioUnit u, AudioUnitRenderActionFlags *f, const AudioTimeStamp *t,
                         UInt32 bus, UInt32 n, AudioBufferList *io) {
    OSStatus s = origAUR(u, f, t, bus, n, io);
    if (!VCamProbeSilenced()) {
        static _Atomic uint64_t c = 0;
        uint64_t k = atomic_fetch_add(&c, 1) + 1;
        if ((k % 500) == 1) {
            UInt32 bufs = io ? io->mNumberBuffers : 0;
            UInt32 bytes = (io && bufs) ? io->mBuffers[0].mDataByteSize : 0;
            int nz = VCamBufNonZero(io);
            VCamProbeLog([NSString stringWithFormat:
                @"probe AURender u=%p bus=%u frames=%u bufs=%u bytes=%u nz=%d calls=%llu",
                u, (unsigned)bus, (unsigned)n, (unsigned)bufs, (unsigned)bytes, nz, k]);
        }
    }
    return s;
}

// ---- AudioUnitProcess ----
static OSStatus (*origAUP)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                           UInt32, AudioBufferList *);
static OSStatus probeAUP(AudioUnit u, AudioUnitRenderActionFlags *f, const AudioTimeStamp *t,
                         UInt32 n, AudioBufferList *io) {
    OSStatus s = origAUP(u, f, t, n, io);

    // OBS INJECT (gated): overwrite ONLY the exact mic-effect buffer — a single-buffer, mono, exactly-n
    // float32 unit. IVCAMCameraActive() is the KEY gate: the same mono AudioUnitProcess format is used by
    // PLAYBACK output (Photos/music), so without it the inject bleeds OBS over all device playback (0.6.58
    // — Photos playback carried the OBS sound/tone). Gating on a live capture (VCamEmit heartbeat) confines
    // it to recording. Read is keyed by THIS unit's mSampleTime so each mic-effect unit gets a contiguous
    // OBS stream; underrun -> real mic.
    if (atomic_load_explicit(&gMicInject, memory_order_relaxed) && IVCAMCameraActive() && io && io->mNumberBuffers == 1) {
        AudioBuffer *b = &io->mBuffers[0];
        if (b->mNumberChannels == 1 && b->mData && b->mDataByteSize == n * sizeof(float)) {
            if (VCamMicRead(u, t ? t->mSampleTime : 0.0, (float *)b->mData, n))
                atomic_fetch_add_explicit(&gObsInjected, 1, memory_order_relaxed);
        }
    } else if (atomic_load_explicit(&gMicTone, memory_order_relaxed) && IVCAMCameraActive() && io && io->mNumberBuffers == 1) {
        // TONE TEST (gated OFF by default): 440 Hz sine into the same exact mic buffer, synced to the
        // audio clock so it's continuous regardless of how many units we fill.
        AudioBuffer *b = &io->mBuffers[0];
        if (b->mNumberChannels == 1 && b->mData && b->mDataByteSize == n * sizeof(float)) {
            float *o = (float *)b->mData;
            double t0 = t ? t->mSampleTime : 0.0;
            for (UInt32 i = 0; i < n; i++)
                o[i] = 0.25f * sinf((float)(2.0 * M_PI * 440.0 * (t0 + (double)i) / 48000.0));
            atomic_fetch_add_explicit(&gToneInjected, 1, memory_order_relaxed);
        }
    }

    if (!VCamProbeSilenced()) {
        static _Atomic uint64_t c = 0;
        uint64_t k = atomic_fetch_add(&c, 1) + 1;
        if ((k % 500) == 1) {
            UInt32 bufs = io ? io->mNumberBuffers : 0;
            UInt32 bytes = (io && bufs) ? io->mBuffers[0].mDataByteSize : 0;
            UInt32 ch = (io && bufs) ? io->mBuffers[0].mNumberChannels : 0;
            int nz = VCamBufNonZero(io);
            VCamProbeLog([NSString stringWithFormat:
                @"probe AUProcess u=%p frames=%u bufs=%u ch=%u bytes=%u nz=%d tone=%llu obs=%llu lat=%dms units=%d calls=%llu",
                u, (unsigned)n, (unsigned)bufs, (unsigned)ch, (unsigned)bytes, nz,
                (unsigned long long)atomic_load(&gToneInjected),
                (unsigned long long)atomic_load(&gObsInjected),
                gDbgLatMs, gDbgUnits, k]);
        }
    }
    return s;
}

// ---- AudioConverterFillComplexBuffer (NOISY: our VCamAACDecoder uses this) ----
static OSStatus (*origACF)(AudioConverterRef, AudioConverterComplexInputDataProc, void *,
                           UInt32 *, AudioBufferList *, AudioStreamPacketDescription *);
static OSStatus probeACF(AudioConverterRef cv, AudioConverterComplexInputDataProc proc, void *ud,
                         UInt32 *ioSz, AudioBufferList *out, AudioStreamPacketDescription *pd) {
    OSStatus s = origACF(cv, proc, ud, ioSz, out, pd);
    if (!VCamProbeSilenced()) {
        static _Atomic uint64_t c = 0;
        uint64_t k = atomic_fetch_add(&c, 1) + 1;
        if ((k % 500) == 1) {
            UInt32 bytes = (out && out->mNumberBuffers) ? out->mBuffers[0].mDataByteSize : 0;
            int nz = VCamBufNonZero(out);
            VCamProbeLog([NSString stringWithFormat:
                @"probe ACFill cv=%p outBytes=%u nz=%d calls=%llu (ours=VCamAACDecoder)",
                cv, (unsigned)bytes, nz, k]);
        }
    }
    return s;
}

// ---- AudioConverterConvertComplexBuffer ----
static OSStatus (*origACC)(AudioConverterRef, UInt32, const AudioBufferList *, AudioBufferList *);
static OSStatus probeACC(AudioConverterRef cv, UInt32 nframes, const AudioBufferList *in,
                         AudioBufferList *out) {
    OSStatus s = origACC(cv, nframes, in, out);
    if (!VCamProbeSilenced()) {
        static _Atomic uint64_t c = 0;
        uint64_t k = atomic_fetch_add(&c, 1) + 1;
        if ((k % 500) == 1) {
            UInt32 bytes = (out && out->mNumberBuffers) ? out->mBuffers[0].mDataByteSize : 0;
            int nz = VCamBufNonZero(out);
            VCamProbeLog([NSString stringWithFormat:
                @"probe ACConvert cv=%p frames=%u outBytes=%u nz=%d calls=%llu",
                cv, (unsigned)nframes, (unsigned)bytes, nz, k]);
        }
    }
    return s;
}

%ctor {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"";
        if (![proc isEqualToString:@"mediaserverd"]) return;   // mediaserverd only
        MSHookFunction((void *)AudioUnitRender,                 (void *)probeAUR, (void **)&origAUR);
        MSHookFunction((void *)AudioUnitProcess,                (void *)probeAUP, (void **)&origAUP);
        MSHookFunction((void *)AudioConverterFillComplexBuffer, (void *)probeACF, (void **)&origACF);
        MSHookFunction((void *)AudioConverterConvertComplexBuffer, (void *)probeACC, (void **)&origACC);
        MSHookFunction((void *)AudioComponentInstanceNew,       (void *)probeACIN, (void **)&origACIN);
        VCamLog(@"probe: mediaserverd audio probe installed (AURender/AUProcess/ACFill/ACConvert/NEWUNIT) — log-only");

        // Feed the OBS mic ring from the shared AAC decoder by wrapping the existing PCM sink, so the
        // stock-Camera emit ring keeps working AND the AUProcess hook has OBS audio to inject.
        gPrevSink = gVCamPCMSink ?: IVCAMMediaActivePushPCM;
        gVCamPCMSink = VCamMicFeedSink;

        // Toggle poller: the OBS mic injection is driven by the 替换音频 switch (VCamConfig.replaceAudio,
        // default ON), so the UI controls TikTok's mic just like it controls the video. The legacy
        // vcam_micinject flag file is OR'd in as a no-UI escape hatch. The tone test stays flag-only
        // (vcam_mictone). vcam_miclat sets the fixed playback latency (ms) for lip-sync. Polling here keeps
        // the RT AUProcess hook reading a single atomic (no objc / config lock on the audio thread).
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            NSFileManager *fm = [NSFileManager defaultManager];
            for (;;) {
                BOOL toggleOn = [VCamConfig shared].replaceAudio;
                BOOL flagOn   = [fm fileExistsAtPath:@"/var/mobile/Media/vcam_micinject"];
                atomic_store(&gMicInject, (toggleOn || flagOn) ? 1 : 0);
                atomic_store(&gMicTone,
                             [fm fileExistsAtPath:@"/var/mobile/Media/vcam_mictone"] ? 1 : 0);
                // Fixed playback latency: vcam_miclat holds the target ms (e.g. `echo 150 > ...`).
                NSString *ls = [NSString stringWithContentsOfFile:@"/var/mobile/Media/vcam_miclat"
                                                         encoding:NSUTF8StringEncoding error:nil];
                if (ls) {
                    int ms = [ls intValue];
                    if (ms < 10) ms = 10; else if (ms > 1000) ms = 1000;
                    atomic_store(&gLatMs, (uint32_t)ms);
                }
                sleep(2);
            }
        });
    }
}

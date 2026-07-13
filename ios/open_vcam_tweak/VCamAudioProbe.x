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

#import "VCamLog.h"

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
    if (!VCamProbeSilenced()) {
        static _Atomic uint64_t c = 0;
        uint64_t k = atomic_fetch_add(&c, 1) + 1;
        if ((k % 500) == 1) {
            UInt32 bufs = io ? io->mNumberBuffers : 0;
            UInt32 bytes = (io && bufs) ? io->mBuffers[0].mDataByteSize : 0;
            int nz = VCamBufNonZero(io);
            VCamProbeLog([NSString stringWithFormat:
                @"probe AUProcess u=%p frames=%u bufs=%u bytes=%u nz=%d calls=%llu",
                u, (unsigned)n, (unsigned)bufs, (unsigned)bytes, nz, k]);
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
    }
}

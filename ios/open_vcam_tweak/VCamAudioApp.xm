// ---------------------------------------------------------------------------
// OpenVCam — in-process microphone replacement for CAPTURE APPS (TikTok, etc.).
//
// This is the app-process half of the process-branched audio design:
//   * mediaserverd  -> VCamAudioMS.x (single-latch, replaces the stock Camera's
//                      capture-graph mic). Proven for the stock Camera.
//   * capture apps  -> THIS file (broadcast, in-process AudioUnitRender hook).
//                      Proven for TikTok (the safe AudioBridge model).
//
// Why two mechanisms: hooking AudioUnitRender in mediaserverd with a broadcast
// (fill-every-mic-unit) model breaks the stock Camera's capture-graph source-node
// START (device watchdog bug_type 288). An app like TikTok records through its
// OWN in-process VoiceProcessingIO units, where the broadcast model is device-
// proven. So each app gets the approach that works for it — one package, branch
// by process (the plist loads this dylib into mediaserverd AND the capture apps;
// the %ctor here self-gates to non-mediaserverd, non-stock-Camera processes).
//
// OBS audio source: the SAME RTMP stream the video path pulls. In this process we
// run VCamRTMPSource in audio-only mode (no H264 decode, no frame store) and route
// its decoded PCM here via gVCamPCMSink -> IVCAMAppPushPCM, which resamples to
// 48 kHz (the iOS capture rate) and appends to a small FIFO. The render hook pops
// from that FIFO. No :1936 PC bridge needed — self-contained on the existing RTMP.
//
// Fail-open everywhere: any error / no data / format mismatch -> the real mic.
// ---------------------------------------------------------------------------
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <substrate.h>
#import <math.h>
#import <stdarg.h>

#import "VCamRTMPSource.h"
#import "VCamConfig.h"
#import "VCamControlChannel.h"
#import "VCamAudioSink.h"
#import "VCamLog.h"

#define IVCAM_APP_TARGET_MEDIASERVERD @"mediaserverd"
#define IVCAM_APP_TARGET_CAMERA       @"com.apple.camera"
#define IVCAM_APP_CANON_RATE 48000    // iOS capture units are 48 kHz; resample OBS to this
// FIFO high-water: keep only the freshest ~this many ms of audio. On RTMP connect SRS bursts its
// GOP cache (up to ~1 s of buffered audio); without a tight cap that whole burst sits in the FIFO
// and the audio plays that far behind the (low-latency) video ("画面比声音早"). Trimming to a small
// target keeps the mic audio close to real time so it lines up with the video overwrite. Tunable.
#define IVCAM_APP_BUFFER_MS 150u

static OSStatus (*gOriginalAudioUnitRender)(AudioUnit inUnit,
                                            AudioUnitRenderActionFlags *ioActionFlags,
                                            const AudioTimeStamp *inTimeStamp,
                                            UInt32 inOutputBusNumber,
                                            UInt32 inNumberFrames,
                                            AudioBufferList *ioData) = NULL;

// ---------------------------------------------------------------------------
// In-process audio client: a locked int16 PCM FIFO (canonical 48 kHz) + the pop /
// fill helpers. Ported from the safe AudioBridge (device-proven in TikTok); the
// only change is the source (RTMP push, resampled) instead of the :1936 socket.
// ---------------------------------------------------------------------------
@interface VCamAppAudioClient : NSObject
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) int channels;          // source channels stored in the FIFO (1/2)
@property (nonatomic, strong) NSMutableData *pcm;    // int16 interleaved @ 48 kHz, `channels` ch
@property (nonatomic, strong) NSLock *pcmLock;
+ (instancetype)shared;
- (void)appendResampledFrom:(const int16_t *)pcm frames:(uint32_t)frames rate:(uint32_t)rate channels:(uint32_t)ch;
- (NSData *)popPCMFrames:(NSUInteger)frames targetChannels:(int)targetChannels;
- (BOOL)fillAudioBufferList:(AudioBufferList *)ioData frames:(UInt32)frames asbd:(const AudioStreamBasicDescription *)asbd;
@end

@implementation VCamAppAudioClient

+ (instancetype)shared {
    static VCamAppAudioClient *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [[VCamAppAudioClient alloc] init]; });
    return c;
}

- (instancetype)init {
    if ((self = [super init])) {
        _enabled = YES;
        _channels = 2;
        _pcm = [NSMutableData data];
        _pcmLock = [[NSLock alloc] init];
    }
    return self;
}

// Producer (RTMP/AAC thread, off-RT). Resample source -> 48 kHz (linear), then append the int16
// interleaved PCM to the FIFO, capped at ~1 s so latency stays bounded (drop oldest).
- (void)appendResampledFrom:(const int16_t *)pcm frames:(uint32_t)frames rate:(uint32_t)rate channels:(uint32_t)ch {
    if (!pcm || frames == 0 || !(ch == 1 || ch == 2) || rate == 0) return;

    NSData *out;
    if (rate == IVCAM_APP_CANON_RATE) {
        out = [NSData dataWithBytes:pcm length:(NSUInteger)frames * ch * sizeof(int16_t)];
    } else if (frames >= 2) {
        double step = (double)rate / (double)IVCAM_APP_CANON_RATE;
        NSUInteger outCap = (NSUInteger)((double)frames / step) + 2;
        NSMutableData *md = [NSMutableData dataWithLength:outCap * ch * sizeof(int16_t)];
        int16_t *o = (int16_t *)md.mutableBytes;
        double pos = 0.0; NSUInteger n = 0;
        while (n < outCap && pos < (double)(frames - 1)) {
            long idx = (long)pos; double frac = pos - (double)idx;
            for (uint32_t c = 0; c < ch; c++) {
                int16_t a = pcm[idx * ch + c], b = pcm[(idx + 1) * ch + c];
                o[n * ch + c] = (int16_t)lround((double)a + ((double)b - (double)a) * frac);
            }
            n++; pos += step;
        }
        md.length = n * ch * sizeof(int16_t);
        out = md;
    } else {
        return;
    }

    [self.pcmLock lock];
    if (self.channels != (int)ch) { self.channels = (int)ch; self.pcm.length = 0; }  // format change
    [self.pcm appendData:out];
    NSUInteger maxBytes = (NSUInteger)IVCAM_APP_CANON_RATE * IVCAM_APP_BUFFER_MS / 1000u * ch * sizeof(int16_t);
    if (self.pcm.length > maxBytes) {
        [self.pcm replaceBytesInRange:NSMakeRange(0, self.pcm.length - maxBytes) withBytes:NULL length:0];
    }
    [self.pcmLock unlock];
}

- (NSData *)popPCMFrames:(NSUInteger)frames targetChannels:(int)targetChannels {
    if (!self.enabled || !(targetChannels == 1 || targetChannels == 2)) return nil;
    int srcCh = self.channels;
    if (!(srcCh == 1 || srcCh == 2)) return nil;

    NSUInteger needSource = frames * (NSUInteger)srcCh * sizeof(int16_t);
    [self.pcmLock lock];
    if (self.pcm.length < needSource) { [self.pcmLock unlock]; return nil; }
    NSData *source = [self.pcm subdataWithRange:NSMakeRange(0, needSource)];
    [self.pcm replaceBytesInRange:NSMakeRange(0, needSource) withBytes:NULL length:0];
    [self.pcmLock unlock];

    if (srcCh == targetChannels) return source;

    const int16_t *in = (const int16_t *)source.bytes;
    NSMutableData *conv = [NSMutableData dataWithLength:frames * (NSUInteger)targetChannels * sizeof(int16_t)];
    int16_t *o = (int16_t *)conv.mutableBytes;
    if (srcCh == 1 && targetChannels == 2) {
        for (NSUInteger i = 0; i < frames; i++) { int16_t s = in[i]; o[i * 2] = s; o[i * 2 + 1] = s; }
    } else {  // 2 -> 1
        for (NSUInteger i = 0; i < frames; i++) o[i] = (int16_t)(((int32_t)in[i * 2] + (int32_t)in[i * 2 + 1]) / 2);
    }
    return conv;
}

- (BOOL)fillAudioBufferList:(AudioBufferList *)ioData frames:(UInt32)frames asbd:(const AudioStreamBasicDescription *)asbd {
    if (!self.enabled || !ioData || !asbd || frames == 0) return NO;
    if (asbd->mSampleRate != (Float64)IVCAM_APP_CANON_RATE) return NO;   // require 48 kHz (we resampled to it)
    if (asbd->mFormatID != kAudioFormatLinearPCM) return NO;

    BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL isSignedInt = (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    BOOL nonInterleaved = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 targetCh = asbd->mChannelsPerFrame;
    if (targetCh == 0 && nonInterleaved) targetCh = ioData->mNumberBuffers;
    if (!(targetCh == 1 || targetCh == 2)) return NO;
    if (!((isFloat && asbd->mBitsPerChannel == 32) || (isSignedInt && asbd->mBitsPerChannel == 16))) return NO;

    NSData *payload = [self popPCMFrames:frames targetChannels:(int)targetCh];
    if (!payload) return NO;
    const int16_t *samples = (const int16_t *)payload.bytes;

    if (isFloat) {
        if (nonInterleaved) {
            if (ioData->mNumberBuffers < targetCh) return NO;
            for (UInt32 ch = 0; ch < targetCh; ch++) {
                if (!ioData->mBuffers[ch].mData) return NO;
                float *out = (float *)ioData->mBuffers[ch].mData;
                UInt32 wf = MIN(frames, ioData->mBuffers[ch].mDataByteSize / (UInt32)sizeof(float));
                for (UInt32 i = 0; i < wf; i++) out[i] = (float)samples[i * targetCh + ch] / 32768.0f;
                ioData->mBuffers[ch].mDataByteSize = wf * (UInt32)sizeof(float);
            }
        } else {
            if (ioData->mNumberBuffers < 1 || !ioData->mBuffers[0].mData) return NO;
            float *out = (float *)ioData->mBuffers[0].mData;
            UInt32 ws = MIN(frames * targetCh, ioData->mBuffers[0].mDataByteSize / (UInt32)sizeof(float));
            for (UInt32 i = 0; i < ws; i++) out[i] = (float)samples[i] / 32768.0f;
            ioData->mBuffers[0].mDataByteSize = ws * (UInt32)sizeof(float);
        }
        return YES;
    }
    // int16
    if (nonInterleaved) {
        if (ioData->mNumberBuffers < targetCh) return NO;
        for (UInt32 ch = 0; ch < targetCh; ch++) {
            if (!ioData->mBuffers[ch].mData) return NO;
            int16_t *out = (int16_t *)ioData->mBuffers[ch].mData;
            UInt32 wf = MIN(frames, ioData->mBuffers[ch].mDataByteSize / (UInt32)sizeof(int16_t));
            for (UInt32 i = 0; i < wf; i++) out[i] = samples[i * targetCh + ch];
            ioData->mBuffers[ch].mDataByteSize = wf * (UInt32)sizeof(int16_t);
        }
    } else {
        if (ioData->mNumberBuffers < 1 || !ioData->mBuffers[0].mData) return NO;
        NSUInteger bytes = MIN((NSUInteger)ioData->mBuffers[0].mDataByteSize, payload.length);
        memcpy(ioData->mBuffers[0].mData, payload.bytes, bytes);
        ioData->mBuffers[0].mDataByteSize = (UInt32)bytes;
    }
    return YES;
}

@end

// Routable PCM sink installed in this process: the AAC decoder pushes here.
static void IVCAMAppPushPCM(const int16_t *pcm, uint32_t srcFrames, uint32_t srcRate, uint32_t srcCh, int64_t ptsMs) {
    (void)ptsMs;
    [[VCamAppAudioClient shared] appendResampledFrom:pcm frames:srcFrames rate:srcRate channels:srcCh];
}

// Broadcast render hook: any mic-input (bus 1) render pops OBS audio from the FIFO. Fail-open.
static OSStatus VCamAppAudioUnitRender(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags,
                                       const AudioTimeStamp *inTimeStamp, UInt32 inOutputBusNumber,
                                       UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = gOriginalAudioUnitRender
        ? gOriginalAudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData)
        : noErr;
    if (status != noErr || !ioData) return status;
    if (inOutputBusNumber != 1) return status;

    AudioStreamBasicDescription asbd;
    UInt32 size = sizeof(asbd);
    memset(&asbd, 0, sizeof(asbd));
    OSStatus fs = AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, inOutputBusNumber, &asbd, &size);
    if (fs != noErr) {
        size = sizeof(asbd);
        fs = AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input, inOutputBusNumber, &asbd, &size);
    }
    if (fs != noErr) return status;

    [[VCamAppAudioClient shared] fillAudioBufferList:ioData frames:inNumberFrames asbd:&asbd];
    return status;
}

// ---------------------------------------------------------------------------
// Constructor: gate to non-mediaserverd, non-stock-Camera capture apps.
// ---------------------------------------------------------------------------
%ctor {
    @autoreleasepool {
        @try {
            NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"";
            NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
            // mediaserverd handles its own capture graph (VCamAudioMS.x); the stock Camera records
            // through mediaserverd, so leave both to that path. Everything else that loads this
            // dylib (TikTok, ...) gets the in-process broadcast mic replacement.
            if ([proc isEqualToString:IVCAM_APP_TARGET_MEDIASERVERD]) return;
            if ([bundle isEqualToString:IVCAM_APP_TARGET_CAMERA]) return;
            // SpringBoard loads this dylib only for the floating panel (VCamFloatingPanel);
            // it is not a capture app, so never install the mic hook there.
            if ([proc isEqualToString:@"SpringBoard"] ||
                [bundle isEqualToString:@"com.apple.springboard"]) return;

            VCamConfig *cfg = [VCamConfig shared];
            if (!cfg.enabled) { VCamLog(@"app-audio: disabled by config in %@", proc); return; }

            VCamLog(@"app-audio: in-process mic replacement loading in bundle=%@ process=%@", bundle, proc);

            // Route the shared AAC decoder's PCM into this process's FIFO, then pull the RTMP
            // stream AUDIO-ONLY (no video decode) so the FIFO gets OBS audio.
            gVCamPCMSink = IVCAMAppPushPCM;
            [VCamRTMPSource shared].audioOnly = YES;
            [[VCamRTMPSource shared] ensureStarted];

            MSHookFunction((void *)AudioUnitRender, (void *)VCamAppAudioUnitRender,
                           (void **)&gOriginalAudioUnitRender);
            VCamLog(@"app-audio: AudioUnitRender hook installed (broadcast, RTMP audio-only source)");

            // Hot on/off from the floating panel's "替换音频" switch. TikTok's sandbox can't
            // read the config file, so the toggle can only arrive over the Darwin-notify bus:
            // flip client.enabled here (when NO, fillAudioBufferList bails -> the real mic).
            dispatch_block_t applyAudioToggle = ^{
                BOOL on = YES, e = YES, v = YES, a = YES;   // default ON until the panel publishes
                if (VCamControlReadState(&e, &v, &a)) on = (e && a);
                [VCamAppAudioClient shared].enabled = on;
            };
            applyAudioToggle();
            VCamControlObserve(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), applyAudioToggle);
        } @catch (NSException *e) {
            VCamLog(@"app-audio: ctor exception %@ — inactive (fail-open)", e);
        }
    }
}

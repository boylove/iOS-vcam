#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Accelerate/Accelerate.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <stdarg.h>
#import <string.h>
#import <os/lock.h>

#import "VCamConfig.h"
#import "VCamFrameStore.h"
#import "VCamRTMPSource.h"
#import "VCamAudioSink.h"
#import "VCamZoom.h"
#import "VCamLog.h"

// ---------------------------------------------------------------------------
// OpenVCam — mediaserverd camera replacement.
//
// Replicates the closed com.x.vcamera approach per the deep binary reverse
// (../../docs/VCAMERA_OPENVCAM_COMPLETE_REFERENCE.md §2): hook the terminal BufferWorks
// node `BWNodeOutput -emitSampleBuffer:` inside mediaserverd and OVERWRITE THE
// CAMERA'S OWN CVImageBuffer IN PLACE with the decoded RTMP frame via
// VTPixelTransferSessionTransferImage, then pass the SAME (now-overwritten) sample
// buffer to the original. In-place overwrite of the shared IOSurface is what actually
// reaches every client's live preview — apps read that upstream surface directly, so
// emitting a fresh downstream buffer never reaches them (that was the earlier bug).
// Using VideoToolbox (not CIContext), on the terminal emit only (never the
// BWPixelTransferNode), is why the original neither lags nor crashes stock-Camera
// recording. Because mediaserverd sits below every app, this replaces the camera for
// all clients, including RootHide-patched apps (TikTok) that bypass app-level tweak
// injection.
//
// ONE GPU PASS PER FRAME, NO PIXEL ROTATION. The closed vcamera transfers the raw
// decoded frame straight into the camera buffer with a single
// VTPixelTransferSessionTransferImage and does NOT run a per-frame
// VTPixelRotationSession (dynamic RE, memory openvcam-photomode-original-flow: photo
// mode logs exactly one transfer/frame). Orientation is carried by the pipeline's
// existing BWVideoOrientationMetadataNode metadata (hooked pass-through only), which
// the system applies at display/encode — no pixel rotation is needed. An earlier build
// added a SECOND GPU pass (rotate into a shared intermediate, then transfer); that
// extra pass on a shared surface is what closed the GPU IOSurface fence cycle (bug_type
// 284 iofence) and froze mediaserverd on the stock-Camera video<->photo switch.
// Removing it — one direct transfer, like the original — is the fix.
//
// Still-photo capture needs NO dedicated hook: emitSampleBuffer: overwrites the
// upstream shared IOSurface, and the still-image pipeline downstream reads that same
// already-OBS surface (the original's own photo-node hooks are all pass-throughs — see
// VCAMERA_OPENVCAM_COMPLETE_REFERENCE.md §2, memory vcamera-photo-hooks-all-passthrough).
//
// Fail-open everywhere; a missing/stale decoded frame -> pure pass-through (never a
// black or frozen frame).
// ---------------------------------------------------------------------------

#define VCAM_LOG_NAME @"OpenVCam.log"

// VCAM_DEST_COLOR (default 1 = ON, matching the closed vcamera). Sets the transfer
// session's DESTINATION colour (ITU-R 709 primaries/transfer, per-path YCbCr matrix),
// exactly what the original sets on all three of its transfer sessions (RE
// 0x82494-0x82504). Without it VT infers the destination colour, which comes out WRONG
// for the still-capture buffer. Set 0 only to A/B the inferred-colour behaviour.
#ifndef VCAM_DEST_COLOR
#define VCAM_DEST_COLOR 1
#endif

// Orientation. Faithful to the closed vcamera's camera-overwrite path: the pre-rotation is
// `create90ImageBuffer:` (RE 0x829e0) = kVTRotation_CCW90, NO flip, for BOTH cameras — done
// on INGEST (VCamFrameStore -ingestSampleBuffer:), not here. The front-camera selfie mirror is the
// downstream capture pipeline's job (as for the real front camera), so the tweak adds no
// flip. (The "back CW90 / front CCW90+FlipVertical by position" at 0x83e20 is the `run`
// loop's DIFFERENT path (ivars 0xc8/0xd0), which the camera overwrite never reads.)
//   VCAM_AUTO_ORIENT: at emit, pick raw (0°) vs the CCW90 pre-rotated by comparing OBS vs
//     camera aspect — the original's modifyImageBuffer: raw-vs-prerotated select (RE 0x8477c):
//     a portrait TikTok preview matches portrait OBS -> raw; a landscape stock-Camera buffer
//     differs -> the pre-rotated buffer. Set 0 to disable auto-rotate (diagnostic).
#ifndef VCAM_AUTO_ORIENT
#define VCAM_AUTO_ORIENT 1
#endif

// VCAM_GPU_ACCEL (default 1 = GPU, FAITHFUL to the closed vcamera). The original ships
// EnableGPUAcceleratedTransfer=YES on BOTH its transfer session (RE 0x82530) and rotation
// session (RE 0x82650). This STAYS GPU — the photo->video preview cycling on GPU means we are
// still missing something the original does across the mode transition (to be found by RE),
// NOT a reason to switch to CPU. Do not deviate to CPU: replicate whatever keeps the
// original's GPU path stable.
#ifndef VCAM_GPU_ACCEL
#define VCAM_GPU_ACCEL 1
#endif

// VCAM_LANDSCAPE_GATE (default 1 = ON, faithful to the closed vcamera). Overwrite only
// LANDSCAPE (width>=height) destination buffers; the PORTRAIT screen-preview buffer
// (1170x2532) is skipped and INHERITS OBS by propagation from the shared landscape
// capture surface. Device-confirmed that overwriting the portrait DISPLAY buffer directly
// (gate OFF) fences/wedges the GPU (OBS flashes -> freeze -> real camera), so the gate
// stays ON; the freeze between ZSL restarts is fixed instead by making the landscape
// overwrite land synchronously (VCAM_GPU_ACCEL=0, CPU transfer) so propagation is fresh.
// RE: original emit hook 0x7516c-74 (getLive && w>=h) -> modifyImageBuffer.
#ifndef VCAM_LANDSCAPE_GATE
#define VCAM_LANDSCAPE_GATE 1
#endif

// VCAM_DEST_MATRIX_709 (default 0 = 601, matching the closed vcamera). Selects the transfer
// session's DESTINATION YCbCr matrix (the session is configured in VCamFrameStore -init). See
// memory openvcam-photo-red-dest-stamp-p3 for the saved-photo colour history.
#ifndef VCAM_DEST_MATRIX_709
#define VCAM_DEST_MATRIX_709 0
#endif

// VCAM_PHOTO_COLOR — fix for the SAVED-PHOTO RED CAST (preview/record fine; only the saved still
// is red, in ALL lighting, immediately, and its file is ~3x smaller than a real photo). DEVICE-
// DIAGNOSED (0.6.64->0.6.65): pulled the saved HEIC and parsed its nclx colour box — it is tagged
// primaries=12 (Display P3) / transfer=1 (709) / matrix=6 (601), the NORMAL tag for an iPhone photo.
// deferredmediad stamps that P3 tag independently; it does NOT inherit the buffer tag we set in
// mediaserverd (which is why the 0.6.64 tag snapshot/restore did nothing on-device). But the main
// transfer session writes 709-PRIMARIES pixel VALUES into the still buffer, so iOS then interprets
// those 709 values as the wider P3 gamut -> every colour over-saturates toward the gamut edge, and
// since P3 expands RED the most, the photo reddens (and the reduced colour entropy shrinks the HEIC).
// Preview (1728) / record (720) are not re-colour-managed into P3, so they look correct — exactly why
// only the photo reddens. DISTINCT from the archived dark-scene deferred red (REFERENCE §5).
//
// FIX (values, not tags): transfer the still through a SEPARATE session whose DestinationColorPrimaries
// = P3_D65 (VCamFrameStore -stillTransferSession), so VT gamut-maps the OBS frame 709->P3 — a 709 red
// becomes the P3 value for the SAME absolute colour, which then matches the P3 tag and renders correctly.
// SCOPED TO THE STILL BUFFER ONLY (short side >= VCAM_STILL_MIN_DIM); preview/record keep the untouched
// 709 main session (user constraint: do not touch recording).
//   0 = baseline (still uses the 709 main session — the pre-fix red behaviour, for A/B).
//   1 = still uses the P3 session only (0.6.65; re-tags but does NOT remap values — insufficient).
//   2 = DEFAULT (0.6.72): gamut-map the still's VALUES 709->P3 (the real fix, VCamStillGamut709toP3)
//       + red-keep compression (VCAM_PHOTO_REDKEEP) to cancel deferredmediad's still-render red boost.
// Fail-open: if the P3 session is NULL the still falls back to the main session (current behaviour).
#ifndef VCAM_PHOTO_COLOR
#define VCAM_PHOTO_COLOR 2
#endif

// VCAM_STILL_MIN_DIM — a destination buffer whose SHORT side is >= this is treated as the
// full-res still (typical still short side ~3024/3168; preview short side 1728, record 720), so
// the VCAM_PHOTO_COLOR handling applies ONLY to the still and never to preview/record. Tunable
// per device if a model's still geometry differs.
#ifndef VCAM_STILL_MIN_DIM
#define VCAM_STILL_MIN_DIM 2200
#endif

// VCAM_PHOTO_REDKEEP — compiled default red-keep percent for the mode-2 still fix (0..100; 100 = off).
// After the exact 709->P3 value map, this compresses ONLY the red EXCESS over green (a FLAT pull: every
// pixel where R>G is moved toward G by rk = redKeep/100), cancelling deferredmediad's still-render
// re-saturation WITHOUT washing out non-red colours and WITHOUT the hue shift a global desaturation
// causes. It is PROPORTIONAL to each pixel's own red-over-green gap, so it auto-scales across lighting
// while green/blue/neutral/cool pixels stay untouched (skin keeps its blood-red).
// Hot-overridable via /var/tmp/vcam_photored (no rebuild). Device-confirmed skin value = 85.
#ifndef VCAM_PHOTO_REDKEEP
#define VCAM_PHOTO_REDKEEP 85
#endif

// VCAM_PHOTO_EXPOSURE / VCAM_PHOTO_CONTRAST — still-only TONE compensation (percent; 100 = off) that
// counters deferredmediad's Smart-HDR brighten/flatten so the saved photo keeps the OBS source's natural,
// moody tone instead of a washed, glary, "fake/over-processed" look. EXPOSURE is a gain (<100 darkens);
// CONTRAST is an S-curve on LUMA, applied by scaling RGB by L'/L so it changes brightness/contrast only,
// never hue or saturation (a saturation boost was tried on-device and re-pinked the glass). Runs on the
// pre-deferredmediad buffer, so effective values are stronger than a post-hoc grade (deferredmediad
// re-brightens). Hot via /var/tmp/vcam_expo and /var/tmp/vcam_contrast. Compiled defaults are 100/100
// (tone OFF): on device the REAR photo looked right from the gamut + flat red-keep alone, and a darkening
// tone (72/138) came out too dark; the knobs stay hot-tunable for the front camera / future scenes.
#ifndef VCAM_PHOTO_EXPOSURE
#define VCAM_PHOTO_EXPOSURE 100
#endif
#ifndef VCAM_PHOTO_CONTRAST
#define VCAM_PHOTO_CONTRAST 100
#endif


// ---------------------------------------------------------------------------
// Stall watchdog / heartbeat (diagnostic for the "moves once then freezes" bug).
//
// The health line is printed FROM INSIDE the emit hook — so if the capture thread ever
// blocks inside our replacement, that log line never fires again and the freeze looks
// identical to "idle". This heartbeat runs on its OWN thread and reports the emit
// counter from the outside, so a hang shows up as "emits STALLED at N". Pure observer,
// no locks touched — safe to leave on in release builds.
static volatile uint64_t gEmitEntries  = 0;   // VCamEmit entered
static volatile uint64_t gEmitReturns  = 0;   // VCamEmit's orig() returned
static volatile uint64_t gAudioRepl    = 0;   // audio buffers overwritten with OBS PCM at emit

// A/B kill-switch: /var/mobile/Media/vcam_noaudio disables the emit-based mic replacement (video
// overwrite stays). Checked once, cached (Media is a path mediaserverd's sandbox can stat).
static BOOL VCamAudioOff(void) {
    static int off = -1;
    if (off < 0) off = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Media/vcam_noaudio"] ? 1 : 0;
    return off != 0;
}

static void VCamStartHeartbeat(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            uint64_t last = 0;
            BOOL stalledLogged = NO;
            for (;;) {
                sleep(2);
                uint64_t now          = gEmitEntries;
                uint64_t emitInflight = gEmitEntries - gEmitReturns;
                if (now != last) {                 // frames still flowing -> healthy
                    last = now;
                    stalledLogged = NO;
                } else if (now > 0 && !stalledLogged) {
                    // Counter was advancing and has now been frozen for ~2s: the capture
                    // thread is blocked, not merely idle (idle still emits real-camera
                    // frames, so the counter keeps rising).
                    stalledLogged = YES;
                    VCamLog(@"HEARTBEAT: emits STALLED at %llu (emitInflight=%llu) "
                            "-> mediaserverd capture thread BLOCKED IN LIVE OVERWRITE",
                            now, emitInflight);
                }
            }
        });
    });
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------
static NSString *VCamLogPath(void) {
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length > 0) return [tmp stringByAppendingPathComponent:VCAM_LOG_NAME];
    return [@"/tmp" stringByAppendingPathComponent:VCAM_LOG_NAME];
}

// Rotate the log when it reaches this size, keeping ONE previous generation (.1). mediaserverd
// is a long-lived daemon (it does not restart per app launch), so on a multi-day continuous
// session an un-capped log grows without bound; this bounds on-disk use to ~2x the threshold.
#define VCAM_LOG_MAX_BYTES (1 * 1024 * 1024)   // 1 MiB per file -> ~2 MiB worst case with the .1

// VCamLog is called concurrently from the RTMP, decode, emit and heartbeat threads. Serialise
// with one lock and reuse a single always-open handle: this fixes the previous per-call
// fileHandleForWritingAtPath race (independent handles each seeked to end and could overwrite
// one another's bytes, not just interleave lines) and drops the per-line open/seek/close. The
// write stays SYNCHRONOUS under the lock (not dispatched to a queue): this is the crash/error
// log, and a synchronous write guarantees the last lines are on disk before a crash, and keeps
// the file order consistent with the synchronous NSLog above. At the release log rate (~one
// line every 10-20s) lock contention is negligible.
static os_unfair_lock gLogLock = OS_UNFAIR_LOCK_INIT;
static NSFileHandle *gLogHandle = nil;   // reused across calls; reopened after a rotation
static BOOL gLogOpenFailed = NO;         // sandbox denied the file -> stop retrying, NSLog only

// Caller must hold gLogLock. Opens gLogHandle (creating the file if needed) unless a prior
// open failed. Leaves gLogHandle nil on failure.
static void VCamLogOpenLocked(void) {
    if (gLogHandle || gLogOpenFailed) return;
    NSString *path = VCamLogPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        if (![fm createFileAtPath:path contents:nil attributes:nil]) { gLogOpenFailed = YES; return; }
    }
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { gLogOpenFailed = YES; return; }   // sandbox denied writes: give up, keep NSLog
    [h seekToEndOfFile];
    gLogHandle = h;
}

// Caller must hold gLogLock. If the open file has reached the size cap, close it, move it to
// "<path>.1" (replacing any previous generation), and reopen a fresh empty file.
static void VCamLogRotateIfNeededLocked(void) {
    if (!gLogHandle) return;
    unsigned long long size = 0;
    @try { size = [gLogHandle offsetInFile]; } @catch (__unused NSException *e) { return; }
    if (size < VCAM_LOG_MAX_BYTES) return;

    @try { [gLogHandle closeFile]; } @catch (__unused NSException *e) {}
    gLogHandle = nil;

    NSString *path = VCamLogPath();
    NSString *prev = [path stringByAppendingPathExtension:@"1"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:prev error:nil];          // drop the older generation (best-effort)
    [fm moveItemAtPath:path toPath:prev error:nil]; // current -> .1
    VCamLogOpenLocked();                            // reopen a fresh, empty current file
}

void VCamLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[OpenVCam] %@", message);

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    os_unfair_lock_lock(&gLogLock);
    @try {
        VCamLogOpenLocked();
        if (gLogHandle) {
            [gLogHandle writeData:data];
            VCamLogRotateIfNeededLocked();
        }
    } @catch (__unused NSException *e) {
        // A mid-write failure can leave a bad handle; drop it so the next call reopens.
        gLogHandle = nil;
    }
    os_unfair_lock_unlock(&gLogLock);
}

// ---------------------------------------------------------------------------
// VideoToolbox pixel-transfer session.
//
// The closed vcamera converts the decoded RTMP frame into a camera-format buffer with
// VTPixelTransferSession (scale + pixel-format / colour-range conversion), NOT
// CoreImage. CIContext rendering a decoded frame into a biplanar YCbCr (420v/420f)
// buffer with a NULL colour space came out BLACK downstream; VTPixelTransferSession does
// the YCbCr<->YCbCr and video<->full-range conversion correctly. The session adapts to
// the src/dst buffers on each call, so we create it once and reuse it, serialised by
// VCamFrameStore's single engine lock (held across the emit pick + transfer) because the
// capture graph can service several source nodes concurrently. This is the ONLY GPU pass in
// the emit hot path — the CCW90 pre-rotation happens once per frame on the decode thread.
// ---------------------------------------------------------------------------
// The transfer session (== engine ivar 0x88) is created + configured at init INSIDE
// VCamFrameStore, alongside the rotation session — both eager, both faithful to the closed
// vcamera's engine init (0x82494 transfer / 0x82650 rotation). The emit gets it via
// [store transferSession] and runs its single VTPixelTransferSessionTransferImage under the
// same engine lock.

// Always-on failure-reason counters so the periodic health line reports WHY an overwrite
// was skipped (fail-open): no fresh decoded frame, no transfer session, or the VT
// transfer failed. Read in the health line; that is the reliable diagnostic
// (startup-gated debug logs fire before a syslog capture can attach).
static uint64_t gRNoFresh, gRNoXfer, gRXferFail;

// ---------------------------------------------------------------------------
// Rotation moved to INGEST — faithful to the closed vcamera. The decoded OBS frame is
// pre-rotated CCW90 on the decode thread inside VCamFrameStore (-ingestSampleBuffer: ->
// create90ImageBuffer: equivalent, ivar 0x70); the emit hot path below does NO rotation —
// it only picks raw-vs-prerotated + one transfer (== modifyImageBuffer: 0x84458). Both run
// under VCamFrameStore's single engine lock, so rotate and transfer never overlap on the
// GPU (splitting that into two locks is what caused the 0.5.7 IOSurface-fence deadlock).
// ---------------------------------------------------------------------------

// Pick raw (return 0) vs the CCW90 pre-rotated (return 90), FAITHFUL to the closed vcamera's
// modifyImageBuffer: select (RE 0x8477c-0x847b4): a plain orientation-CLASS comparison on the
// integer w/h, NOT an aspect-ratio distance. Rotated iff src and dst orientations DIFFER —
// src landscape (w>h) with dst portrait (w<h), or src portrait with dst landscape. Square
// (w==h) on either side -> raw (matches the original's >= / <= boundaries: 0x84790 b.ge,
// 0x84798 b.le). This is robust to atypical/near-square/transient buffer geometries, unlike
// an aspect-ratio minimiser.
#if VCAM_AUTO_ORIENT
static long VCamAutoOrientDegrees(CVPixelBufferRef src, CVImageBufferRef dst) {
    size_t sw = CVPixelBufferGetWidth(src),  sh = CVPixelBufferGetHeight(src);
    size_t dw = CVPixelBufferGetWidth(dst),  dh = CVPixelBufferGetHeight(dst);
    if (!sw || !sh || !dw || !dh) return 0;
    if ((sw > sh && dw < dh) || (sw < sh && dw > dh)) return 90;   // orientations differ
    return 0;
}
#endif

// Overwrites the camera's OWN CVImageBuffer IN PLACE with the decoded RTMP frame,
// exactly like the closed vcamera's -[<core> modifyImageBuffer:]: it calls
// VTPixelTransferSessionTransferImage(session, OBS frame, CAMERA image buffer), writing
// straight into the camera's shared IOSurface. THAT is what actually reaches the app's
// live preview — apps read that shared surface directly, so substituting a new sample
// buffer downstream does not reach them. Returns YES on overwrite; on any failure returns
// NO and the caller passes the real frame.
static uint64_t gRPortrait;   // landscape-gate skips (health diagnostic)

#if VCAM_PHOTO_COLOR
// Is this destination the full-res still (vs preview/record)? Scoped by short side so the colour
// handling NEVER touches the video/preview path (user constraint: recording is already correct).
// Device-confirmed geometry (0.6.64 syslog): still short side 3168/3024; preview 1728; record 720.
static BOOL VCamIsStillBuffer(CVImageBufferRef buf) {
    size_t w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf);
    size_t shortSide = (w < h) ? w : h;
    return shortSide >= (size_t)VCAM_STILL_MIN_DIM;
}

// Runtime photo-colour mode, hot-overridable via a one-byte flag file ('0'..'2'); falls back to the
// compiled VCAM_PHOTO_COLOR default. Re-read at most ~every 2s (stills are rare, so negligible).
//   0 = still uses the 709 main session (pre-fix red baseline)
//   1 = still uses the P3-dest session (0.6.65 — tag only, still red: VT does not remap values)
//   2 = still is GAMUT-MAPPED 709->P3 in pixel VALUES (0.6.67 fix) so it matches its P3 tag
// PATH: /var/tmp is the dir mediaserverd's sandbox can actually read on this RootHide device — it is
// where the log lives and where VCamConfig's vc.plist is read from (device log: "config
// source=/var/tmp/vc.plist"; the /var/mobile/Media candidates are tried first and FAIL). 0.6.67 read
// the flag from /var/mobile/Media and so never saw it (still fell back to the compiled default).
// /var/mobile/Media is kept as a second try for app-level contexts.
static int VCamPhotoColorMode(void) {
    static int cached = -1;
    static NSTimeInterval last = 0;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (cached < 0 || now - last >= 2.0) {
        last = now;
        int m = VCAM_PHOTO_COLOR;
        for (NSString *path in @[ @"/var/tmp/vcam_photocolor", @"/var/mobile/Media/vcam_photocolor" ]) {
            NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
            if (s.length > 0) {
                unichar c = [s characterAtIndex:0];
                if (c >= '0' && c <= '9') { m = c - '0'; break; }
            }
        }
        cached = m;
    }
    return cached;
}

// Still-photo RED-KEEP percent (0..100; 100 = OFF/unchanged), hot via /var/tmp/vcam_photored.
// A straight colour-managed 709->P3 value map (mode 2) removes the primaries over-saturation, but the
// saved photo's MIDTONES stay redder than the 709 preview/record because deferredmediad RE-SATURATES
// the still it renders. Global desaturation (0.6.70) cancelled the red but ALSO washed out every other
// colour (pale/over-exposed look). So instead this compresses ONLY the red EXCESS over green (rk scales
// the R-G gap where R>G); green/blue/neutral/cool pixels are untouched, so the picture keeps its
// vividness while the warm/red cast comes down. Tuned on-device against a same-scene video reference:
// lower it until the photo's midtone R-G matches the video's. Still-only; never touches preview/record.
static int VCamPhotoRedKeep(void) {
    static int cached = -1;
    static NSTimeInterval last = 0;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (cached < 0 || now - last >= 2.0) {
        last = now;
        int v = VCAM_PHOTO_REDKEEP;
        NSString *str = [NSString stringWithContentsOfFile:@"/var/tmp/vcam_photored"
                                                  encoding:NSUTF8StringEncoding error:NULL];
        if (str.length > 0) {
            int n = [str intValue];
            if (n >= 0 && n <= 100) v = n;
        }
        cached = v;
    }
    return cached;
}

// Still-only TONE compensation knobs (percent, 100 = off) — counter deferredmediad's HDR brighten/flatten.
static int VCamPhotoExposure(void) {   // gain; <100 darkens. Hot via /var/tmp/vcam_expo.
    static int cached = -1;
    static NSTimeInterval last = 0;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (cached < 0 || now - last >= 2.0) {
        last = now;
        int v = VCAM_PHOTO_EXPOSURE;
        NSString *str = [NSString stringWithContentsOfFile:@"/var/tmp/vcam_expo"
                                                  encoding:NSUTF8StringEncoding error:NULL];
        if (str.length > 0) { int n = [str intValue]; if (n >= 10 && n <= 200) v = n; }
        cached = v;
    }
    return cached;
}
static int VCamPhotoContrast(void) {   // luma S-curve strength. Hot via /var/tmp/vcam_contrast.
    static int cached = -1;
    static NSTimeInterval last = 0;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (cached < 0 || now - last >= 2.0) {
        last = now;
        int v = VCAM_PHOTO_CONTRAST;
        NSString *str = [NSString stringWithContentsOfFile:@"/var/tmp/vcam_contrast"
                                                  encoding:NSUTF8StringEncoding error:NULL];
        if (str.length > 0) { int n = [str intValue]; if (n >= 50 && n <= 300) v = n; }
        cached = v;
    }
    return cached;
}

// THE FIX (0.6.67): write TRUE Display-P3 pixel values into the full-res still, so the colour the
// P3-tagged HEIC renders equals the OBS colour the (709) preview/record already show correctly.
// Device-diagnosed chain: the still buffer is natively P3-tagged (prim=P3_D65) and 10-bit LOSSLESS
// (fmt &xf0), deferredmediad keeps that P3 tag, but our transfer writes 709-primaries VALUES into it
// (VTPixelTransferSession's DestinationColorPrimaries only re-tags, it does NOT gamut-convert — the
// on-device 709-vs-P3 probe proved identical values). 709 values under a P3 tag over-saturate toward
// the gamut edge, reddest first -> the red cast. Fix path (all still-only, rare, fail-open):
//   1) VT: OBS src (420f 709) -> BGRA scratch (VT decodes YCbCr->RGB; the still is lossless so it is
//      NOT directly writable by vImage — hence the plain-BGRA detour);
//   2) vImage colour-managed 709->DisplayP3 on that plain BGRA (CPU/Accelerate, no GPU fence — safe
//      in mediaserverd, unlike a CIContext) — this is the actual gamut remap;
//   3) VT: BGRA(P3 values) -> the still buffer (scaled), so it now holds P3 values under its P3 tag.
// Returns YES only if all three steps succeed; on ANY failure the caller keeps the plain transfer
// (== current red behaviour, never worse, never a black/again frame). The video/preview path never
// calls this (guarded by isStill upstream).
static BOOL VCamStillGamut709toP3(CVPixelBufferRef src, CVImageBufferRef still) {
    if (!src || !still) return NO;
    size_t sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src);
    if (sw == 0 || sh == 0) return NO;

    // Lazy, reused: the two colour spaces and the single-plane BGRA 709->DisplayP3 vImage converter.
    static CGColorSpaceRef cs709 = NULL, csP3 = NULL;
    static vImageConverterRef gCvt = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cs709 = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
        csP3  = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
        if (cs709 && csP3) {
            // 32-bit BGRA (the layout VTPixelTransferSession writes for kCVPixelFormatType_32BGRA):
            // little-endian 0xAARRGGBB, alpha in the high byte -> NoneSkipFirst | ByteOrder32Little.
            vImage_CGImageFormat f709 = {
                .bitsPerComponent = 8, .bitsPerPixel = 32, .colorSpace = cs709,
                .bitmapInfo = (CGBitmapInfo)(kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little),
                .version = 0, .decode = NULL, .renderingIntent = kCGRenderingIntentDefault,
            };
            vImage_CGImageFormat fP3 = f709; fP3.colorSpace = csP3;
            vImage_Error e = kvImageNoError;
            gCvt = vImageConverter_CreateWithCGImageFormat(&f709, &fP3, NULL, kvImageNoFlags, &e);
            if (!gCvt) VCamLog(@"photo-fix: vImage converter create failed (%ld)", (long)e);
        }
    });
    if (!gCvt) return NO;

    BOOL ok = NO;
    CVPixelBufferRef rgb709 = NULL, rgbP3 = NULL;
    VTPixelTransferSessionRef toRGB = NULL, toYUV = NULL;
    NSDictionary *bgra = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
                            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
    do {
        // 1) OBS src (420f, 709) -> rgb709 (BGRA, src size). VT decodes YCbCr->RGB (601 matrix, 709).
        if (CVPixelBufferCreate(kCFAllocatorDefault, sw, sh, kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)bgra, &rgb709) != kCVReturnSuccess) break;
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &toRGB) != noErr || !toRGB) break;
        if (VTPixelTransferSessionTransferImage(toRGB, src, rgb709) != noErr) break;

        // 2) vImage colour-managed 709 -> DisplayP3 on the plain BGRA (the real gamut remap).
        if (CVPixelBufferCreate(kCFAllocatorDefault, sw, sh, kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)bgra, &rgbP3) != kCVReturnSuccess) break;
        BOOL wrote = NO;
        if (CVPixelBufferLockBaseAddress(rgb709, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
            if (CVPixelBufferLockBaseAddress(rgbP3, 0) == kCVReturnSuccess) {
                vImage_Buffer s = { CVPixelBufferGetBaseAddress(rgb709), sh, sw, CVPixelBufferGetBytesPerRow(rgb709) };
                vImage_Buffer d = { CVPixelBufferGetBaseAddress(rgbP3),  sh, sw, CVPixelBufferGetBytesPerRow(rgbP3) };
                vImage_Error e = vImageConvert_AnyToAny(gCvt, &s, &d, NULL, kvImageNoFlags);
                wrote = (e == kvImageNoError);
                // Compress ONLY the red EXCESS over green (where R>G, pull R toward G by (1-rk); G, B and
                // every cool/neutral pixel are untouched, so nothing washes out) to trim deferredmediad's
                // still-render red boost. Flat rk = redKeep/100; result stays in [0,255] (G <= R' <= R).
                // redKeep == 100 -> skip. Still-only.
                int redKeep = VCamPhotoRedKeep();       // red-keep % (100 = off)
                if (wrote && redKeep < 100) {
                    float rk = redKeep / 100.0f;
                    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(rgbP3);
                    size_t rb2 = CVPixelBufferGetBytesPerRow(rgbP3);
                    for (size_t yy = 0; yy < sh; yy++) {
                        uint8_t *row = base + yy * rb2;
                        for (size_t xx = 0; xx < sw; xx++) {
                            uint8_t *px = row + xx * 4;   // BGRA byte order
                            float Gv = px[1], Rv = px[2];
                            if (Rv > Gv) px[2] = (uint8_t)(Gv + rk * (Rv - Gv) + 0.5f);
                        }
                    }
                }
                // Still-only TONE compensation: counter deferredmediad's Smart-HDR brighten/flatten (the
                // washed, glary, "fake" look) so the saved photo keeps the natural, moody tone of the OBS
                // source. Exposure = gain; contrast = an S-curve on LUMA with RGB scaled by L'/L, i.e.
                // brightness/contrast only, never hue or saturation (a saturation boost re-pinked the glass
                // on-device). Runs on the pre-deferredmediad buffer, so values are stronger than a post-hoc
                // grade. Hot-tunable; skipped when both neutral (100). Values clamped to [0,255].
                int expo = VCamPhotoExposure();     // gain %, 100 = off
                int contrast = VCamPhotoContrast(); // luma S-curve %, 100 = off
                if (wrote && (expo != 100 || contrast != 100)) {
                    float gain = expo / 100.0f, con = contrast / 100.0f;
                    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(rgbP3);
                    size_t rb2 = CVPixelBufferGetBytesPerRow(rgbP3);
                    for (size_t yy = 0; yy < sh; yy++) {
                        uint8_t *row = base + yy * rb2;
                        for (size_t xx = 0; xx < sw; xx++) {
                            uint8_t *px = row + xx * 4;   // BGRA
                            float bb = px[0] * gain, gg = px[1] * gain, rr = px[2] * gain;
                            float L = 0.2126f * rr + 0.7152f * gg + 0.0722f * bb;
                            if (L > 0.5f) {
                                float Ln2 = (L / 255.0f - 0.5f) * con + 0.5f;
                                if (Ln2 < 0.0f) Ln2 = 0.0f; else if (Ln2 > 1.0f) Ln2 = 1.0f;
                                float scale = (Ln2 * 255.0f) / L;
                                rr *= scale; gg *= scale; bb *= scale;
                            }
                            if (rr < 0.0f) rr = 0.0f; else if (rr > 255.0f) rr = 255.0f;
                            if (gg < 0.0f) gg = 0.0f; else if (gg > 255.0f) gg = 255.0f;
                            if (bb < 0.0f) bb = 0.0f; else if (bb > 255.0f) bb = 255.0f;
                            px[0] = (uint8_t)(bb + 0.5f); px[1] = (uint8_t)(gg + 0.5f); px[2] = (uint8_t)(rr + 0.5f);
                        }
                    }
                }
                // Sanity/A-B trace (once): the values actually written to the still (post 709->P3, post red-keep).
                static BOOL tracedFix = NO;
                if (!tracedFix) {
                    tracedFix = YES;
                    uint8_t *p = (uint8_t *)CVPixelBufferGetBaseAddress(rgb709);
                    uint8_t *q = (uint8_t *)CVPixelBufferGetBaseAddress(rgbP3);
                    size_t br = CVPixelBufferGetBytesPerRow(rgb709), o = (sh/2)*br + (sw/2)*4;
                    if (p && q) VCamLog(@"photo-fix: gamut e=%ld redkeep=%d expo=%d con=%d 709BGRA[%d %d %d] -> outBGRA[%d %d %d]",
                                        (long)e, redKeep, expo, contrast, p[o],p[o+1],p[o+2], q[o],q[o+1],q[o+2]);
                }
                CVPixelBufferUnlockBaseAddress(rgbP3, 0);
            }
            CVPixelBufferUnlockBaseAddress(rgb709, kCVPixelBufferLock_ReadOnly);
        }
        if (!wrote) break;

        // 3) rgbP3 (BGRA, P3 values) -> still (lossless 10-bit P3, scaled). RGB->YCbCr matrix only;
        //    values already P3, so the still now matches the P3 tag deferredmediad stamps.
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &toYUV) != noErr || !toYUV) break;
        VTSessionSetProperty(toYUV, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Trim);
        VTSessionSetProperty(toYUV, kVTPixelTransferPropertyKey_DestinationColorPrimaries, kCVImageBufferColorPrimaries_P3_D65);
        VTSessionSetProperty(toYUV, kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4);
        if (VTPixelTransferSessionTransferImage(toYUV, rgbP3, still) != noErr) break;
        ok = YES;
    } while (0);

    if (toRGB) { VTPixelTransferSessionInvalidate(toRGB); CFRelease(toRGB); }
    if (toYUV) { VTPixelTransferSessionInvalidate(toYUV); CFRelease(toYUV); }
    if (rgb709) CVPixelBufferRelease(rgb709);
    if (rgbP3)  CVPixelBufferRelease(rgbP3);
    return ok;
}
#endif

static BOOL VCamOverwriteInPlace(CVImageBufferRef cameraBuf) {
    if (!cameraBuf) return NO;
    VCamConfig *cfg = [VCamConfig shared];
    if (!cfg.enabled || !cfg.replaceVideo) return NO;   // "替换视频" off -> pass the real camera

#if VCAM_LANDSCAPE_GATE
    // Overwrite only LANDSCAPE buffers, like the closed vcamera (see VCAM_LANDSCAPE_GATE).
    // Portrait buffers inherit OBS from the shared landscape capture surface, so skipping
    // them is invisible AND keeps the overwrite rate at the original's level. Not a
    // failure: a portrait dst legitimately needs no direct overwrite.
    if (CVPixelBufferGetWidth(cameraBuf) < CVPixelBufferGetHeight(cameraBuf)) {
        gRPortrait++;
        return NO;
    }
#endif

    VCamFrameStore *store = [VCamFrameStore shared];
    VTPixelTransferSessionRef xfer = [store transferSession];   // created eagerly at store init
    if (!xfer) { gRNoXfer++; return NO; }
    // Single engine-lock critical section across pick + transfer — the SAME lock the ingest
    // holds while pre-rotating (faithful to the original's one ivar-0x18 lock across
    // setYUVSampleBuffer: and modifyImageBuffer:). NO rotation and NO flip here: the ingest
    // already produced the CCW90 buffer, and the front-camera selfie mirror is the downstream
    // capture pipeline's job (as it is for the real front camera).
    if (![store beginEmitAccess]) { gRNoFresh++; return NO; }
    CVPixelBufferRef raw = [store rawFrameLocked];
    CVPixelBufferRef rot = [store rotatedFrameLocked];
    // Pick raw (same orientation as dst) vs the CCW90 pre-rotated (differing) — exactly the
    // original's modifyImageBuffer: raw-vs-prerotated select (RE 0x8477c-0x847b4).
    CVPixelBufferRef src = raw;
#if VCAM_AUTO_ORIENT
    BOOL usedRotated = (rot && VCamAutoOrientDegrees(raw, cameraBuf) == 90);
    if (usedRotated) src = rot;
#else
    BOOL usedRotated = NO;
#endif
    size_t srcW = CVPixelBufferGetWidth(src), srcH = CVPixelBufferGetHeight(src);

    // STILL-PHOTO COLOUR FIX (device-diagnosed 0.6.64->0.6.65; scoped to the full-res still ONLY).
    // The saved HEIC is tagged Display P3 (nclx primaries=12) by deferredmediad, but the main 709
    // session writes 709-primaries pixel VALUES into the still buffer, so iOS reads 709 values as the
    // wider P3 -> over-saturation toward the gamut edge (reddest first, P3 expands red most) = red cast
    // + smaller file. The still session is identical EXCEPT DestinationColorPrimaries=P3_D65, so VT
    // gamut-maps 709->P3 and the pixel values match the P3 tag. Preview/record (short side <
    // VCAM_STILL_MIN_DIM) keep the main 709 session, byte-for-byte unchanged. Fail-open: if the still
    // session is NULL (creation failed), use the main session (== current 0.6.64 behaviour).
    VTPixelTransferSessionRef useXfer = xfer;
#if VCAM_PHOTO_COLOR
    BOOL isStill = VCamIsStillBuffer(cameraBuf);
    int pcMode = 0;                        // 0=709 baseline, 1=P3-tag session, 2=gamut-map fix
    CVPixelBufferRef stillSrc = NULL;      // +1 retained OBS src for the mode-2 gamut fix
    if (isStill) {
        pcMode = VCamPhotoColorMode();
        VTPixelTransferSessionRef sxfer = [store stillTransferSession];
        // mode 0 keeps the 709 main session; modes 1 & 2 use the P3-dest session as the base transfer
        // (mode 2 then remaps the VALUES afterwards, which is the part that actually fixes the red).
        if (pcMode >= 1 && sxfer) useXfer = sxfer;
        if (src) stillSrc = (CVPixelBufferRef)CVPixelBufferRetain(src);
        static int loggedMode = -1;
        if (loggedMode != pcMode) {
            loggedMode = pcMode;
            VCamLog(@"photo-color: still %zux%zu mode=%d (%@)",
                    CVPixelBufferGetWidth(cameraBuf), CVPixelBufferGetHeight(cameraBuf), pcMode,
                    pcMode == 0 ? @"709 baseline" : (pcMode == 2 ? @"gamut-map fix" : @"P3 tag only"));
        }
    }
#endif

    // ZOOM-FOLLOW (跟随变焦). When the switch is on and the app has zoomed (factor>1), centre-crop
    // the OBS src by 1/factor and transfer it through the crop session so the injected image tracks
    // the pinch-zoom — keeping the picture consistent with the reported focal length. Scoped to
    // preview/record (NOT the full-res still: that keeps its P3 colour session, and a stills-zoom is
    // rare + would fight the colour fix). We ALWAYS set the crop state on the chosen src (factor 1.0
    // clears it) so a recycled buffer never carries a stale crop when zoom is off. Fail-open: if the
    // zoom session is missing or the crop can't be set, fall back to the normal session (no crop).
    double zoomFactor = 1.0;
    BOOL zoomApplied = NO;
#if VCAM_PHOTO_COLOR
    BOOL zoomEligible = !isStill;
#else
    BOOL zoomEligible = YES;
#endif
    BOOL zoomHaveSession = NO, zoomCropSet = NO;
    if (cfg.zoomFollow && zoomEligible) {
        zoomFactor = VCamZoomCurrentFactor();     // >=1.0, clamped by the probe
        VTPixelTransferSessionRef zxfer = [store zoomTransferSession];
        zoomHaveSession = (zxfer != NULL);
        zoomCropSet = [store setCenterCropOnSource:src factor:zoomFactor];
        if (zxfer && zoomCropSet) {
            useXfer = zxfer;
            zoomApplied = YES;
        }
    }
    if (!zoomApplied) {
        [store setCenterCropOnSource:src factor:1.0];   // clear any stale crop on a recycled buffer
    }
    // ZOOM diagnostic: log when the factor the emit path actually READS changes (change-based, not
    // per-frame spam). Distinguishes "emit sees stale 1.0" from "factor ok but crop/session missing".
    // Reports the src the crop attaches to (rotated buffers are a separate CVPixelBuffer from raw).
    if (cfg.zoomFollow) {
        static double lastZ = -1.0;
        if (fabs(zoomFactor - lastZ) >= 0.05) {
            lastZ = zoomFactor;
            double zf = zoomFactor; BOOL hs = zoomHaveSession, cs = zoomCropSet, ap = zoomApplied;
            BOOL rotd = usedRotated; size_t sw = srcW, sh = srcH;
            VCamLog(@"zoom-emit: read=%.3f haveSession=%d cropSet=%d applied=%d src=%zux%zu rotated=%d",
                    zf, (int)hs, (int)cs, (int)ap, sw, sh, (int)rotd);
        }
    }

    // ONE transfer. Preview/video use the 709 main session (or the crop session when following zoom);
    // the full-res still uses the P3 session (VCAM_PHOTO_COLOR) so the saved photo's pixel values match
    // its P3 tag. ScalingMode=Trim aspect-fills (CropSourceToCleanAperture when zooming).
    OSStatus ts = VTPixelTransferSessionTransferImage(useXfer, src, cameraBuf);

    [store endEmitAccess];

#if VCAM_PHOTO_COLOR
    // Still-only mode-2 COLOUR FIX, applied AFTER the lock is released. Remaps the still's pixel
    // VALUES 709->P3 (VCamStillGamut709toP3) so they match deferredmediad's P3 tag, then applies the
    // red-keep + tone compensation. Overwrites the baseline transfer above; on failure the baseline
    // (red) result stays. Still-only (guarded by isStill), rare, fail-open; never touches preview/record.
    if (isStill && pcMode == 2 && stillSrc) {
        BOOL fixed = VCamStillGamut709toP3(stillSrc, cameraBuf);
        static int loggedFix = -1;
        if (loggedFix != (fixed ? 1 : 0)) {
            loggedFix = fixed ? 1 : 0;
            VCamLog(@"photo-fix: gamut-map %@",
                    fixed ? @"applied (still now holds P3 values)" : @"FAILED -> kept baseline transfer");
        }
    }
    if (stillSrc) CVPixelBufferRelease(stillSrc);
#endif

    // One-time geometry diagnostic (first few distinct dst sizes), logged AFTER unlock so
    // the lock is held only around the transfer.
    {
        static long loggedDst[6]; static int nLogged = 0;
        long key = (long)CVPixelBufferGetWidth(cameraBuf) * 100000 + (long)CVPixelBufferGetHeight(cameraBuf);
        BOOL seen = NO;
        for (int i = 0; i < nLogged; i++) if (loggedDst[i] == key) { seen = YES; break; }
        if (!seen && nLogged < 6) {
            loggedDst[nLogged++] = key;
            VCamLog(@"geom: src=%zux%zu dst=%zux%zu rotated=%d zoomFollow=%d zoom=%.2f",
                    srcW, srcH,
                    CVPixelBufferGetWidth(cameraBuf), CVPixelBufferGetHeight(cameraBuf),
                    usedRotated, (int)cfg.zoomFollow, zoomFactor);
        }
    }

    if (ts != noErr) {
        gRXferFail++;
        static BOOL logged = NO;
        if (!logged) { logged = YES; VCamLog(@"transfer failed (%d) src=%zux%zu dst=%zux%zu",
                                              (int)ts, srcW, srcH,
                                              CVPixelBufferGetWidth(cameraBuf), CVPixelBufferGetHeight(cameraBuf)); }
        return NO;
    }
    return YES;
}

// VCAM_VIDEO_DEDUP (default 0). The camera graph re-emits the SAME frame through many
// BWNodeOutput instances (~5-10x/frame). DEVICE-PROVEN (2026-07-12): overwriting every one
// transfers ~5x/frame into the channel-0 ISP RENDERED-pool buffers, exhausting the pool (H13ISP
// 'Unable to allocate a replacement buffer' x220) and HALVING capture fps (30->15); the closed
// original transfers ONCE/frame (0 ISP errors at 30fps). With dedup ON we skip a frame we already
// overwrote, keyed on the system TransitionID (kCMSampleBufferAttachmentKey_TransitionID,
// ShouldPropagate) — the same key the original uses (RE 0.5.4). Historical caveat: this was blamed
// for photo↔video mode-switch sharp/blur cycling, but that is a MODE SWITCH artifact, not a
// during-recording one; photo node hooks are off by default.
#ifndef VCAM_VIDEO_DEDUP
#define VCAM_VIDEO_DEDUP 1   // DEVICE-PROVEN default: without it fps halves (30->15, ISP pool exhausted)
#endif

// ---------------------------------------------------------------------------
// Hook plumbing for private mediaserverd classes (objc_getClass + MSHookMessageEx)
// ---------------------------------------------------------------------------
static NSMutableDictionary<NSValue *, NSValue *> *gEmitOrigs;    // Class -> IMP
static uint64_t gRDup;                                           // deduped (already-OBS) emits

static IMP VCamFindOrig(NSMutableDictionary<NSValue *, NSValue *> *map, id obj) {
    Class c = object_getClass(obj);
    while (c) {
        NSValue *v = map[[NSValue valueWithPointer:(__bridge void *)c]];
        if (v) return (IMP)[v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

// -[BWNodeOutput emitSampleBuffer:] — overwrite the camera's image buffer IN PLACE
// (exactly like vcamera's -[<core> modifyImageBuffer:]), then call the original with the
// ORIGINAL sample buffer. This is the ONLY node the original modifies; the render nodes
// are left untouched (see the deep reverse report).
static void VCamEmit(id self, SEL _cmd, CMSampleBufferRef sb) {
    IMP orig = VCamFindOrig(gEmitOrigs, self);
    if (!orig) return;
    gEmitEntries++;                            // heartbeat: entered (before any work)
    IVCAMNoteCameraActive();                   // mark camera capture active (gates the mediaserverd mic inject)
    [[VCamRTMPSource shared] ensureStarted];   // idempotent; keeps the RTMP puller alive
    CVImageBufferRef ib = sb ? CMSampleBufferGetImageBuffer(sb) : NULL;
    BOOL did = NO;
    if (ib) {
#if VCAM_VIDEO_DEDUP
        // Overwrite each frame EXACTLY ONCE: the graph re-emits the same buffer ~5-10x/frame and
        // transferring into all of them exhausts the ISP RENDERED pool -> 30->15fps. If we already
        // stamped this buffer, it's a re-emit -> pass through; else overwrite + stamp so the
        // re-emits (which carry the ShouldPropagate attachment) are skipped. Keyed on the system
        // TransitionID like the original.
        if (CMGetAttachment(sb, kCMSampleBufferAttachmentKey_TransitionID, NULL) != NULL) {
            gRDup++;
            did = YES;   // already overwritten with OBS -> pass through
        } else {
            did = VCamOverwriteInPlace(ib);
            if (did) CMSetAttachment(sb, kCMSampleBufferAttachmentKey_TransitionID,
                                     (__bridge CFTypeRef)@(1), kCMAttachmentMode_ShouldPropagate);
        }
#else
        // No dedup (the landscape gate alone bounds the rate). DEVICE-DISPROVEN on the
        // memory-tight device — see VCAM_VIDEO_DEDUP; build with =1 to overwrite once/frame.
        did = VCamOverwriteInPlace(ib);
#endif
    } else if (sb && [VCamConfig shared].replaceAudio && !VCamAudioOff()) {
        // AUDIO overwrite (0.6.45): replace the capture graph's mic PCM with OBS audio IN PLACE —
        // gated by the floating panel's "替换音频" switch (cfg.replaceAudio) and the vcam_noaudio file.
        // exactly like the video image buffer above, via the SAME emit hook, OFF the hot
        // AudioUnitRender IO path (which dropped fps 29.98->24 and SIGTRAP-crashed repeat-record).
        // Dedup by TransitionID like video: the graph re-emits each buffer ~3x, so overwrite ONCE
        // and let the re-emits carry the OBS audio. Only packed signed-int16 interleaved mono/stereo
        // (the capture graph's format, matching the OBS AAC); anything else falls open to the mic.
        // Dedup with a PRIVATE key, NOT the system TransitionID: stamping TransitionID on the AUDIO
        // buffer makes the movie muxer treat it as a transition/discontinuity and throttle the video
        // to 24 fps (video uses TransitionID fine, but on audio it drops fps). A private key is
        // ignored by the muxer, so it dedups without the fps hit. (0.6.46)
        CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
        if (fd && CMFormatDescriptionGetMediaType(fd) == kCMMediaType_Audio &&
            CMGetAttachment(sb, CFSTR("VCamAudioDedup"), NULL) == NULL) {
            const AudioStreamBasicDescription *a = CMAudioFormatDescriptionGetStreamBasicDescription(fd);
            if (a && a->mFormatID == kAudioFormatLinearPCM && a->mBitsPerChannel == 16 &&
                (a->mFormatFlags & kAudioFormatFlagIsSignedInteger) &&
                !(a->mFormatFlags & kAudioFormatFlagIsNonInterleaved) &&
                (a->mChannelsPerFrame == 1 || a->mChannelsPerFrame == 2)) {
                CMItemCount nsamp = CMSampleBufferGetNumSamples(sb);
                size_t need = (size_t)nsamp * a->mChannelsPerFrame * 2u;
                CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
                size_t lenAt = 0, total = 0; char *ptr = NULL;
                if (nsamp > 0 && nsamp < 65536 && bb &&
                    CMBlockBufferGetDataPointer(bb, 0, &lenAt, &total, &ptr) == kCMBlockBufferNoErr &&
                    ptr && lenAt >= need) {
                    if (IVCAMAudioPopForEmit((int16_t *)ptr, (uint32_t)nsamp,
                                             (uint32_t)a->mSampleRate, a->mChannelsPerFrame)) {
                        gAudioRepl++;
                    } else if (IVCAMAudioOBSStreaming()) {
                        memset(ptr, 0, need);   // OBS live but no PCM yet -> mute (no real-mic leak)
                    }
                    CMSetAttachment(sb, CFSTR("VCamAudioDedup"), kCFBooleanTrue,
                                    kCMAttachmentMode_ShouldPropagate);
                }
            }
        }
    }
    ((void (*)(id, SEL, CMSampleBufferRef))orig)(self, _cmd, sb);   // original sb, now overwritten
    gEmitReturns++;                            // heartbeat: orig returned (emit not blocked)

    // Always-on health line: distinguishes "OBS not showing" (replaced=0) from
    // "decoder idle / fail-open" via syslog; the why[] counters pinpoint the cause.
    static uint64_t calls = 0, repl = 0;
    calls++;
    if (did) {
        IVCAMSetOBSStreaming(1);   // OBS content confirmed live -> audio hook mutes the real mic
                                   // during the audio-startup window instead of recording it
        repl++;
        if (repl == 1) VCamLog(@"health: first frame replaced (OBS is live)");
    }
    if ((calls % 600) == 0) {
        uint64_t aPush = 0, aHit = 0, aMiss = 0; uint32_t aRate = 0, aCh = 0, aFillMs = 0;
        IVCAMAudioStats(&aPush, &aHit, &aMiss, &aRate, &aCh, &aFillMs);
        VCamLog(@"health: emits=%llu replaced=%llu dup=%llu why[noFresh=%llu noXfer=%llu xferFail=%llu portrait=%llu] "
                 "audio[repl=%llu push=%llu hit=%llu miss=%llu rate=%u ch=%u fillMs=%u]",
                calls, repl, gRDup, gRNoFresh, gRNoXfer, gRXferFail, gRPortrait,
                gAudioRepl, aPush, aHit, aMiss, aRate, aCh, aFillMs);
    }
}


static void VCamHook(const char *clsName, SEL sel, IMP repl,
                     NSMutableDictionary<NSValue *, NSValue *> *origMap) {
    Class c = objc_getClass(clsName);
    if (!c) { VCamLog(@"class %s not found", clsName); return; }
    if (!class_getInstanceMethod(c, sel)) {
        VCamLog(@"%s has no %@", clsName, NSStringFromSelector(sel));
        return;
    }
    IMP orig = NULL;
    MSHookMessageEx(c, sel, repl, &orig);
    if (orig) {
        origMap[[NSValue valueWithPointer:(__bridge void *)c]] =
            [NSValue valueWithPointer:(const void *)orig];
        VCamLog(@"hooked %s %@", clsName, NSStringFromSelector(sel));
    }
}

%ctor {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"";
        if (![proc isEqualToString:@"mediaserverd"]) return;   // safety: mediaserverd only

        gEmitOrigs = [NSMutableDictionary dictionary];

        VCamConfig *cfg = [VCamConfig shared];
        VCamLog(@"loading in mediaserverd, enabled=%d url=%@", cfg.enabled, cfg.rtmpURL);

        // Hook ONLY the terminal BWNodeOutput emitSampleBuffer:. Per the binary analysis
        // of the closed vcamera (VCAMERA_OPENVCAM_COMPLETE_REFERENCE.md §2), that is the
        // single place it modifies the frame: it overwrites the camera's own image buffer
        // IN PLACE there (via VTPixelTransfer), and passes the same sample buffer on.
        // Modifying the shared IOSurface is what reaches the app's live preview. vcamera
        // hooks the render nodes too but only as pass-through, so we don't hook them at
        // all — which also avoids the BWPixelTransferNode recording-crash path entirely.
        // The still-image pipeline reads the same already-overwritten shared surface, so
        // the shutter captures OBS with no dedicated photo hook.
        VCamHook("BWNodeOutput", @selector(emitSampleBuffer:), (IMP)VCamEmit, gEmitOrigs);

        // Start the stall watchdog BEFORE frames flow: it reports from its own thread if
        // the capture thread ever wedges inside our hook, so the "moves once then freezes"
        // symptom shows up as "emits STALLED" instead of silence.
        VCamStartHeartbeat();

        // Start pulling immediately; frames only get used once enabled + fresh.
        [[VCamRTMPSource shared] ensureStarted];
        // Log the compile config so the syslog itself proves WHICH build is running.
        VCamLog(@"hooks installed (%lu emit) DEST_COLOR=%d DEST_MATRIX_709=%d GPU_ACCEL=%d LANDSCAPE_GATE=%d",
                (unsigned long)gEmitOrigs.count,
                VCAM_DEST_COLOR, VCAM_DEST_MATRIX_709, VCAM_GPU_ACCEL, VCAM_LANDSCAPE_GATE);
    }
}

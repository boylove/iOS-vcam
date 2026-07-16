#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <stdarg.h>
#import <string.h>
#import <os/lock.h>

#import "VCamConfig.h"
#import "VCamFrameStore.h"
#import "VCamRTMPSource.h"
#import "VCamAudioSink.h"
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

// VCAM_PHOTO_COLOR — fix for the SAVED-PHOTO RED CAST (preview/record are fine, only the still
// thumbnail + opened photo are red, in ALL lighting, immediately). Root cause (memory
// openvcam-photo-red-dest-stamp-p3, reconfirmed by control 0.6.5): the ONE 601/709 transfer
// session writes into EVERY destination buffer including the full-res still, so it stamps ITU-R
// 709 colour tags onto the still buffer. That still buffer is wide-gamut (Display P3), so the
// HEIC encoder re-colour-manages the 709-tagged pixels into P3 and PUSHES RED. Preview (1728) /
// record (720) buffers are not re-colour-managed the same way, so they look correct — which is
// exactly why only the photo reddens. This is DISTINCT from the archived dark-scene deferred red
// (VCAMERA_OPENVCAM_COMPLETE_REFERENCE.md §5: dark-only, appears on swipe-back, preview fine).
//
// The fix is SCOPED TO THE STILL BUFFER ONLY (short side >= VCAM_STILL_MIN_DIM) so the video /
// preview colour path is byte-for-byte unchanged (user constraint: do not touch recording).
//   0 = baseline (no colour handling; the pre-fix behaviour — A/B reference).
//   1 = DEFAULT: snapshot the still buffer's OWN (native P3) colour tags BEFORE the transfer and
//       RESTORE them AFTER, overwriting the 709 the session stamps. The saved photo is then
//       colour-managed with its native tags, matching the real camera.
//   2 = STRIP: remove the colour tags from the still buffer after the transfer, so the encoder
//       infers colour from the buffer's own format instead of the 709 stamp (fallback if 1 still
//       reds — e.g. if the native tags themselves are the wrong ones).
// Fail-open: any failure leaves the already-overwritten pixels in place; the photo still saves.
#ifndef VCAM_PHOTO_COLOR
#define VCAM_PHOTO_COLOR 1
#endif

// VCAM_STILL_MIN_DIM — a destination buffer whose SHORT side is >= this is treated as the
// full-res still (typical still short side ~3024/3168; preview short side 1728, record 720), so
// the VCAM_PHOTO_COLOR handling applies ONLY to the still and never to preview/record. Tunable
// per device if a model's still geometry differs.
#ifndef VCAM_STILL_MIN_DIM
#define VCAM_STILL_MIN_DIM 2200
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
// The colour-management tags that decide how the encoder interprets the pixels. The transfer
// session stamps these (709) onto its destination; on the wide-gamut still buffer that is what
// reddens the saved photo, so we snapshot/restore ONLY these on the still buffer. The keys are
// extern `const CFStringRef` (NOT compile-time constants), so they can't initialise a file-scope
// static array in C — fill a caller-provided local array at runtime instead.
enum { kVCamColorKeyCount = 4 };
static void VCamColorKeys(CFStringRef keys[kVCamColorKeyCount]) {
    keys[0] = kCVImageBufferColorPrimariesKey;
    keys[1] = kCVImageBufferTransferFunctionKey;
    keys[2] = kCVImageBufferYCbCrMatrixKey;
    keys[3] = kCVImageBufferICCProfileKey;
}

// Is this destination the full-res still (vs preview/record)? Scoped by short side so the colour
// handling NEVER touches the video/preview path (user constraint: recording is already correct).
static BOOL VCamIsStillBuffer(CVImageBufferRef buf) {
    size_t w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf);
    size_t shortSide = (w < h) ? w : h;
    return shortSide >= (size_t)VCAM_STILL_MIN_DIM;
}

// Snapshot the still buffer's OWN colour tags into `out` (each +1 retained or NULL). Uses
// CVBufferCopyAttachment (CVBufferGetAttachment is deprecated under -Werror).
static void VCamColorSnapshot(CVImageBufferRef buf, CFTypeRef out[kVCamColorKeyCount]) {
    CFStringRef keys[kVCamColorKeyCount];
    VCamColorKeys(keys);
    for (int i = 0; i < kVCamColorKeyCount; i++) {
        // mode is passed NULL (we always re-attach ShouldPropagate below) — the param is nullable.
        out[i] = CVBufferCopyAttachment(buf, keys[i], NULL);
    }
}

// Restore (mode 1) the snapshotted native tags over whatever the transfer stamped, or strip
// (mode 2) the tags entirely so the encoder infers colour from the buffer format. Releases the
// snapshot's +1 references either way.
static void VCamColorRestore(CVImageBufferRef buf, CFTypeRef snap[kVCamColorKeyCount], int mode) {
    CFStringRef keys[kVCamColorKeyCount];
    VCamColorKeys(keys);
    for (int i = 0; i < kVCamColorKeyCount; i++) {
        if (mode == 2) {
            // STRIP: drop the 709 the transfer stamped; let the encoder use the buffer's format.
            CVBufferRemoveAttachment(buf, keys[i]);
        } else if (snap[i]) {
            // RESTORE the buffer's native (P3) tag, overwriting the transfer's 709 stamp.
            CVBufferSetAttachment(buf, keys[i], snap[i], kCVAttachmentMode_ShouldPropagate);
        } else {
            // The still buffer had no such tag natively -> remove the one the transfer added, so
            // we don't leave a 709 stamp the native buffer never carried.
            CVBufferRemoveAttachment(buf, keys[i]);
        }
        if (snap[i]) CFRelease(snap[i]);
    }
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

#if VCAM_PHOTO_COLOR
    // STILL-PHOTO COLOUR FIX (scoped to the full-res still buffer only; preview/record untouched).
    // The single 601 session (0.6.5) stamps 709 primaries/transfer onto whatever it transfers into.
    // On the wide-gamut (Display P3) still buffer the HEIC encoder then re-colour-manages those 709
    // tags into P3 -> reddened saved photo (memory openvcam-photo-red-dest-stamp-p3). Snapshot the
    // still buffer's OWN native tags before the transfer and restore/strip them after, so the encoder
    // reads the pixels in the buffer's native colour space. Preview/record buffers (short side <
    // VCAM_STILL_MIN_DIM) never enter this branch. Fail-open: on any anomaly the pixels are already
    // written and the photo still saves.
    BOOL isStill = VCamIsStillBuffer(cameraBuf);
    CFTypeRef colorSnap[kVCamColorKeyCount] = {0};
    if (isStill) VCamColorSnapshot(cameraBuf, colorSnap);
#endif

    // ONE transfer, one 601 session for every buffer (preview, video, still) — no per-size
    // routing, like the closed vcamera. ScalingMode=Trim (on the session) aspect-fills.
    OSStatus ts = VTPixelTransferSessionTransferImage(xfer, src, cameraBuf);

#if VCAM_PHOTO_COLOR
    if (isStill && ts == noErr) {
        VCamColorRestore(cameraBuf, colorSnap, VCAM_PHOTO_COLOR);
        static BOOL loggedStill = NO;
        if (!loggedStill) {
            loggedStill = YES;
            VCamLog(@"photo-color: still %zux%zu colour %@ (mode %d)",
                    CVPixelBufferGetWidth(cameraBuf), CVPixelBufferGetHeight(cameraBuf),
                    VCAM_PHOTO_COLOR == 2 ? @"stripped" : @"restored to native", VCAM_PHOTO_COLOR);
        }
    } else if (isStill) {
        // Transfer failed: release the snapshot we took (VCamColorRestore would also do this, but
        // we skip it since the pixels weren't overwritten). Fail-open.
        for (int i = 0; i < kVCamColorKeyCount; i++) if (colorSnap[i]) CFRelease(colorSnap[i]);
    }
#endif

    [store endEmitAccess];

    // One-time geometry diagnostic (first few distinct dst sizes), logged AFTER unlock so
    // the lock is held only around the transfer.
    {
        static long loggedDst[6]; static int nLogged = 0;
        long key = (long)CVPixelBufferGetWidth(cameraBuf) * 100000 + (long)CVPixelBufferGetHeight(cameraBuf);
        BOOL seen = NO;
        for (int i = 0; i < nLogged; i++) if (loggedDst[i] == key) { seen = YES; break; }
        if (!seen && nLogged < 6) {
            loggedDst[nLogged++] = key;
            VCamLog(@"geom: src=%zux%zu dst=%zux%zu rotated=%d",
                    srcW, srcH,
                    CVPixelBufferGetWidth(cameraBuf), CVPixelBufferGetHeight(cameraBuf),
                    usedRotated);
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

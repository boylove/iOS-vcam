#import "VCamFrameStore.h"
#import <VideoToolbox/VideoToolbox.h>
#import <time.h>

// VCAM_GPU_ACCEL default (1 = GPU) mirrors Tweak.xm and the closed vcamera, which configures
// its rotation session GPU-accelerated (init 0x82650). Fall back to 0 (CPU) if the device
// preview freezes on the GPU path.
#ifndef VCAM_GPU_ACCEL
#define VCAM_GPU_ACCEL 1
#endif
// Transfer-session destination colour, mirroring Tweak.xm and the closed vcamera (0x82494):
// VCAM_DEST_COLOR pins 709 primaries/transfer; VCAM_DEST_MATRIX_709 picks 709 (else 601) matrix.
#ifndef VCAM_DEST_COLOR
#define VCAM_DEST_COLOR 1
#endif
#ifndef VCAM_DEST_MATRIX_709
#define VCAM_DEST_MATRIX_709 0
#endif

@implementation VCamFrameStore {
    CMSampleBufferRef _rawSample;            // raw decoded frame as CMSampleBuffer (== ivar 0x50)
    CVPixelBufferRef _rotated;               // CCW90 pre-rotated copy   (== engine ivar 0x70)
    VTPixelRotationSessionRef _rotSession;   // CCW90 rotation session   (== engine ivar 0x98)
    VTPixelTransferSessionRef _transferSession; // scale/convert session (== engine ivar 0x88)
    VTPixelTransferSessionRef _stillTransferSession; // STILL-ONLY session: identical config but
                                             // Destination primaries = Display P3, so the OBS
                                             // pixels written into the full-res still buffer are
                                             // gamut-mapped 709->P3 to match the P3 tag deferredmediad
                                             // stamps on the saved HEIC (fixes the red cast + small file).
    BOOL _live;                              // overwrite gate           (== engine ivar 9 / _bLive)
    NSRecursiveLock *_lock;                  // THE single engine lock   (== engine ivar 0x18)
    CVPixelBufferPoolRef _rotPool;           // RECYCLES rotated dst buffers (bounds IOSurface churn)
    size_t _rotPoolSrcW, _rotPoolSrcH;       // source dims the pool was sized for (rebuild if changed)
    OSType _rotPoolFmt;
}

+ (instancetype)shared {
    static VCamFrameStore *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[VCamFrameStore alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _rawSample = NULL;
        _rotated = NULL;
        _rotSession = NULL;
        _live = NO;
        // NSRecursiveLock, matching the closed vcamera's engine _lock (0x823f8) — the ingest
        // rotate and the emit transfer share it, and it can re-enter without self-deadlock.
        _lock = [[NSRecursiveLock alloc] init];
        // Create + configure the rotation session HERE at init — faithful to the closed vcamera's
        // engine init (0x82650: EnableGPUAcceleratedTransfer + Rotation = CCW90) — NOT lazily on
        // the first frame. VTPixelRotationSession is iOS 16+; on iOS 15 it stays NULL and
        // create90Locked fails open (no rotation).
        if (@available(iOS 16.0, *)) {
            VTPixelRotationSessionRef rs = NULL;
            if (VTPixelRotationSessionCreate(kCFAllocatorDefault, &rs) == noErr && rs) {
                VTSessionSetProperty(rs, (__bridge CFStringRef)@"EnableGPUAcceleratedTransfer",
                                     VCAM_GPU_ACCEL ? kCFBooleanTrue : kCFBooleanFalse);
                VTSessionSetProperty(rs, kVTPixelRotationPropertyKey_Rotation, kVTRotation_CCW90);
                _rotSession = rs;
            }
        }
        // Transfer session (== engine ivar 0x88) — created + configured HERE at init too, at the
        // SAME time as the rotation session, faithful to the closed vcamera's engine init
        // (0x82494: ScalingMode=Trim, GPU-accel, 709 primaries/transfer + 601/709 matrix). Not
        // iOS-16-gated (VTPixelTransferSession predates it).
        VTPixelTransferSessionRef ts = NULL;
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &ts) == noErr && ts) {
            VTSessionSetProperty(ts, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Trim);
            VTSessionSetProperty(ts, (__bridge CFStringRef)@"EnableGPUAcceleratedTransfer",
                                 VCAM_GPU_ACCEL ? kCFBooleanTrue : kCFBooleanFalse);
#if VCAM_DEST_COLOR
            VTSessionSetProperty(ts, kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                                 kCVImageBufferColorPrimaries_ITU_R_709_2);
            VTSessionSetProperty(ts, kVTPixelTransferPropertyKey_DestinationTransferFunction,
                                 kCVImageBufferTransferFunction_ITU_R_709_2);
            VTSessionSetProperty(ts, kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                                 VCAM_DEST_MATRIX_709 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2
                                                      : kCVImageBufferYCbCrMatrix_ITU_R_601_4);
#endif
            _transferSession = ts;
        }

        // STILL-ONLY transfer session (saved-photo red-cast fix, device-diagnosed 0.6.64->0.6.65).
        // The saved HEIC is tagged Display P3 (nclx primaries=12) by deferredmediad, but the main
        // session above writes 709-primaries pixel VALUES into the still buffer, so iOS interprets
        // 709 values as the wider P3 -> everything over-saturates toward the gamut edge, reddest of
        // all (P3 expands red most) -> red cast + smaller file (colour entropy drops). This session
        // is IDENTICAL to the main one EXCEPT its DestinationColorPrimaries = P3_D65, so VT gamut-maps
        // the OBS frame 709->P3: a 709 red becomes the P3 value for the SAME absolute colour, matching
        // the P3 tag. Used ONLY for the full-res still (Tweak.xm isStill gate); preview/record keep the
        // untouched 709 main session. Created eagerly like the main session; NULL -> Tweak.xm falls
        // back to the main session (fail-open, i.e. current behaviour).
        VTPixelTransferSessionRef sts = NULL;
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &sts) == noErr && sts) {
            VTSessionSetProperty(sts, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Trim);
            VTSessionSetProperty(sts, (__bridge CFStringRef)@"EnableGPUAcceleratedTransfer",
                                 VCAM_GPU_ACCEL ? kCFBooleanTrue : kCFBooleanFalse);
            VTSessionSetProperty(sts, kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                                 kCVImageBufferColorPrimaries_P3_D65);
            VTSessionSetProperty(sts, kVTPixelTransferPropertyKey_DestinationTransferFunction,
                                 kCVImageBufferTransferFunction_ITU_R_709_2);
            VTSessionSetProperty(sts, kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                                 kCVImageBufferYCbCrMatrix_ITU_R_601_4);
            _stillTransferSession = sts;
        }
    }
    return self;
}

- (void)dealloc {
    if (_rawSample) CFRelease(_rawSample);
    if (_rotated) CVPixelBufferRelease(_rotated);
    if (_rotPool) CVPixelBufferPoolRelease(_rotPool);
    if (_rotSession) {
        // _rotSession is only ever created inside the iOS 16 @available block below, so a
        // non-NULL value means we are on iOS 16+; the guard is for the compiler.
        if (@available(iOS 16.0, *)) {
            VTPixelRotationSessionInvalidate((VTPixelRotationSessionRef)_rotSession);
        }
        CFRelease(_rotSession);
    }
    if (_transferSession) {
        VTPixelTransferSessionInvalidate(_transferSession);
        CFRelease(_transferSession);
    }
    if (_stillTransferSession) {
        VTPixelTransferSessionInvalidate(_stillTransferSession);
        CFRelease(_stillTransferSession);
    }
}

- (VTPixelTransferSessionRef)transferSession { return _transferSession; }
- (VTPixelTransferSessionRef)stillTransferSession { return _stillTransferSession; }

// Faithful port of the closed vcamera's `create90ImageBuffer:` (0x829e0): CCW90-rotate
// `src` into a FRESH buffer with swapped W/H, whose IOSurface uses exactly
// { IOSurfacePreallocPages:0, IOSurfacePurgeWhenNotInUse:1 } (RE 0x82a74-0x82af0, key
// strings 0x10ee88/0x10eea8). A fresh buffer every frame — like the original's per-call
// CVPixelBufferCreate — so the NEXT frame's rotation can never alias the buffer the emit is
// mid-transfer on. Caller MUST hold _lock. Returns a +1 buffer, or NULL on failure.
- (CVPixelBufferRef)create90Locked:(CVPixelBufferRef)src CF_RETURNS_RETAINED {
    if (!src) return NULL;
    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);
    OSType fmt = CVPixelBufferGetPixelFormatType(src);
    if (w == 0 || h == 0) return NULL;

    // The rotation session was created + configured at init (not here).
    if (@available(iOS 16.0, *)) {
        if (!_rotSession) return NULL;   // iOS 15 or init failure -> fail open (no rotation)
        // Re-assert Rotation=CCW90 each call, faithful to create90ImageBuffer: (0x82b48). No flip
        // — the camera-overwrite path rotates CCW90 for BOTH cameras; the front selfie mirror is
        // the downstream pipeline's job. (GPU-accel was set once at init, 0x82650.)
        VTSessionSetProperty(_rotSession, kVTPixelRotationPropertyKey_Rotation, kVTRotation_CCW90);

        // Rotated destination comes from a RECYCLING CVPixelBufferPool, not a fresh
        // CVPixelBufferCreate per frame. The rotation swaps W/H, so the pool holds (h x w) buffers.
        // A per-frame create+release churned a new IOSurface every frame; on this memory-tight
        // (re-jailbroken) device that churn exhausted the camera ISP's own IOSurface pool
        // (H13ISP "Unable to allocate a replacement buffer") and HALVED the capture fps (30->15).
        // The pool recycles released surfaces and settles at the in-flight working set (a few
        // buffers held by the async GPU emit), so allocation is bounded — while still handing back a
        // DISTINCT free buffer while the previous is in flight (preserves the anti-alias reason the
        // per-frame create existed). Rebuild the pool only if the source dims/format change.
        if (!_rotPool || _rotPoolSrcW != w || _rotPoolSrcH != h || _rotPoolFmt != fmt) {
            if (_rotPool) { CVPixelBufferPoolRelease(_rotPool); _rotPool = NULL; }
            NSDictionary *ioSurface = @{
                (__bridge id)CFSTR("IOSurfacePreallocPages")     : @0,
                (__bridge id)CFSTR("IOSurfacePurgeWhenNotInUse") : @1,
            };
            NSDictionary *pbAttrs = @{
                (id)kCVPixelBufferWidthKey               : @(h),   // swapped W/H for the quarter turn
                (id)kCVPixelBufferHeightKey              : @(w),
                (id)kCVPixelBufferPixelFormatTypeKey     : @(fmt),
                (id)kCVPixelBufferIOSurfacePropertiesKey : ioSurface,
            };
            CVPixelBufferPoolRef pool = NULL;
            if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                        (__bridge CFDictionaryRef)pbAttrs, &pool) != kCVReturnSuccess || !pool) {
                return NULL;
            }
            _rotPool = pool;
            _rotPoolSrcW = w; _rotPoolSrcH = h; _rotPoolFmt = fmt;
        }

        CVPixelBufferRef dst = NULL;
        if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _rotPool, &dst) != kCVReturnSuccess || !dst) {
            return NULL;
        }
        if (VTPixelRotationSessionRotateImage(_rotSession, src, dst) != noErr) {
            CVPixelBufferRelease(dst);
            return NULL;
        }
        return dst;
    }
    return NULL;
}

- (void)ingestSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return;
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return;
    [_lock lock];
    // Faithful to setYUVSampleBuffer: (0x82ddc) IN THE ORIGINAL'S EXACT ORDER: release the old
    // raw and set it NULL FIRST (0x82e0c str xzr), THEN CMSampleBufferCreateCopy into _rawSample
    // (which is left NULL on the rare failure), THEN release old rotated -> NULL, THEN create90
    // into _rotated. So _rawSample and _rotated ALWAYS come from the SAME input frame — both new,
    // or both cleared — never the old raw paired with a new rotated. (A CMSampleBufferCreateCopy
    // preserves timing + format description + attachments as an independent object, not a retain;
    // and if the copy fails, _rawSample==NULL makes the emit skip, exactly like modifyImageBuffer:
    // 0x84498 which bails when ivar 0x50 is NULL.)
    if (_rawSample) { CFRelease(_rawSample); _rawSample = NULL; }
    CMSampleBufferCreateCopy(kCFAllocatorDefault, sampleBuffer, &_rawSample);   // _rawSample = NULL on failure
    if (_rotated) { CVPixelBufferRelease(_rotated); _rotated = NULL; }
    _rotated = [self create90Locked:(CVPixelBufferRef)imageBuffer];
    [_lock unlock];
}

- (BOOL)beginEmitAccess {
    [_lock lock];
    // Gate on _bLive AND a frame != NULL, exactly like modifyImageBuffer: (0x8448c: ldrb [x0,#9];
    // 0x84498: ldr [x0,#0x50]). NO age check. On disconnect the RTMP layer sets _live = NO but
    // KEEPS the frame, so this returns NO -> real camera, without dropping the last OBS frame.
    if (_live && _rawSample) return YES;   // lock stays held
    [_lock unlock];
    return NO;
}

- (void)setLive:(BOOL)live {
    [_lock lock];
    _live = live;
    [_lock unlock];
}

- (CVPixelBufferRef)rawFrameLocked {
    return _rawSample ? (CVPixelBufferRef)CMSampleBufferGetImageBuffer(_rawSample) : NULL;
}
- (CVPixelBufferRef)rotatedFrameLocked { return _rotated; }
- (void)endEmitAccess { [_lock unlock]; }

- (void)clear {
    [_lock lock];
    if (_rawSample) { CFRelease(_rawSample); _rawSample = NULL; }
    if (_rotated) { CVPixelBufferRelease(_rotated); _rotated = NULL; }
    [_lock unlock];
}

@end

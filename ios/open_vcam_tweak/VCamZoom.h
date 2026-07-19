#import <Foundation/Foundation.h>

// ---------------------------------------------------------------------------
// OpenVCam — live camera-zoom source.
//
// The emit path (Tweak.xm VCamOverwriteInPlace) wants to know the CURRENT zoom
// factor the capture app has requested, so it can centre-crop the OBS frame by
// 1/factor and keep the injected image consistent with the app's pinch-zoom (and
// with the focal length the pipeline reports). That factor is set INSIDE
// mediaserverd on the Fig capture-session config; VCamZoomProbe discovers the
// setter by reflection and records the value here.
//
// This is a passive value store: a single atomic double, safe to read from the
// capture thread with no lock. Until a real setter is observed it returns 1.0
// (no crop) — fail-open, exactly like a missing decoded frame.
// ---------------------------------------------------------------------------

#ifdef __cplusplus
extern "C" {
#endif

/// Current effective zoom factor (>= 1.0). 1.0 means "no zoom" / not yet observed,
/// so the emit path applies no crop. Clamped to [1.0, VCAM_ZOOM_MAX] by the probe.
double VCamZoomCurrentFactor(void);

/// Probe setter (VCamZoomProbe only): record a freshly observed zoom factor. Values
/// <= 0 or NaN are ignored; anything else is clamped into [1.0, VCAM_ZOOM_MAX].
void VCamZoomSetFactor(double factor);

#ifdef __cplusplus
}
#endif

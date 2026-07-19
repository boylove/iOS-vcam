// ---------------------------------------------------------------------------
// OpenVCam — mediaserverd camera-ZOOM source probe + tracker.
//
// PURPOSE. The "跟随变焦" feature centre-crops the OBS frame by 1/zoomFactor so a
// pinch-zoom in the capture app zooms the injected image too. To do that the emit
// path (Tweak.xm) needs the CURRENT zoom factor the app requested. AVFoundation's
// -[AVCaptureDevice videoZoomFactor] runs in the APP; but under RootHide TikTok is
// tweak-free, and in every app the value ultimately lands on a Fig capture object
// INSIDE mediaserverd (the same daemon we already own). So we discover the Fig zoom
// setter by reflection and record the value it receives.
//
// WHY A CURATED ALLOWLIST (not a fixed %hook, not a blind scan). The exact Fig class that
// carries the live zoom differs across iOS builds and is not documented, so a single hard-coded
// %hook would silently no-op on a mismatch. But a blind "any set…Zoom…: setter" scan is just as
// wrong: a dyld-cache dump on the target (iPhone13,2 / iOS 16.1.2) shows DOZENS of unrelated
// set…Zoom…: selectors (UI/Maps/text/home-screen zoom). So we hook a CURATED allowlist of the six
// real capture-pipeline zoom setters (all confirmed present in this runtime), each with a
// priority, and at load we scan the ObjC runtime for whichever classes DECLARE them and hook via
// MSHookMessageEx. The authoritative factor is taken from the highest-priority setter that
// actually fires; the rest are logged only. Every hook and every observed value is logged, so the
// device syslog proves WHICH setter tracks the pinch (its value climbs 1.0 -> N as you zoom) and
// the ranking can be corrected from real data — the same evidence-driven method the audio path
// (VCamAudioProbe) used.
//
// SAFETY. Each trampoline does the minimum on the (possibly real-time) caller thread:
// read one scalar arg, clamp, one atomic store, then call the original. No locks, no
// allocation, no objc messaging beyond object_getClass for orig lookup. It never
// changes the value passed to the original, so the real camera's own zoom is
// untouched — we only OBSERVE it. Discovery + logging are deferred to a background
// queue. Gated to mediaserverd; default on, silence with /var/mobile/Media/vcam_nozoomprobe.
// The emit path only crops when the "跟随变焦" switch is on, so this probe is inert
// (log-only) unless the user opts in.
// ---------------------------------------------------------------------------
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <stdatomic.h>
#import <math.h>
#import <string.h>

#import "VCamZoom.h"
#import "VCamLog.h"

// Clamp ceiling for the observed factor. iPhone digital zoom tops out well below this;
// the ceiling only guards against a bogus/uninitialised Fig value driving a degenerate crop.
#ifndef VCAM_ZOOM_MAX
#define VCAM_ZOOM_MAX 16.0
#endif

// --- Curated capture-zoom setter allowlist -------------------------------------
// DEVICE-VERIFIED (iPhone13,2 / iOS 16.1.2, dyld cache grep 2026-07-18): the runtime exposes
// DOZENS of set…Zoom…: selectors (UI zoom, map POI zoom, text zoom, home-screen zoom, …). A
// blind "name contains zoom" scan would hook all of them and let unrelated setters scribble on
// our single factor store. So we hook only a CURATED allowlist of the genuine capture-pipeline
// zoom setters, each with a PRIORITY. The authoritative factor comes from the highest-priority
// setter that has actually fired; lower-priority ones are observed + logged only (so the
// on-device pinch test can confirm which selector truly tracks the UI zoom and the ranking can be
// corrected from real data without a blind guess). All six are confirmed present in this runtime.
//
// Ranking rationale: ISP zoom is the hardware sensor crop actually applied to the real feed, so
// mimicking it keeps OBS geometry identical to what the sensor would have produced; the Fig/AVF
// video-zoom setters are the next-best proxy for the app's requested factor. NOTE (device TODO):
// on this dual-camera device a wide<->ultrawide lens switch re-bases the per-sensor ISP factor;
// the common wide-sensor pinch (1x->5x) is covered, cross-lens re-basing is a pinch-test item.
typedef struct { const char *sel; int prio; } VCamZoomSel;
static const VCamZoomSel kZoomSels[] = {
    { "setISPZoomFactor:",       60 },  // hardware ISP sensor crop (ground truth of the applied crop)
    { "setVideoZoomFactor:",     50 },  // Fig/AVF capture-stream video zoom (app's requested factor)
    { "setTotalZoomFactor:",     40 },
    { "setRequestedZoomFactor:", 30 },
    { "setCameraZoomFactor:",    20 },
    { "setBaseZoomFactor:",      10 },  // base zoom before GDC (lowest — often just 1.0)
};
static const int kZoomSelCount = (int)(sizeof(kZoomSels) / sizeof(kZoomSels[0]));

// The single shared value store (read lock-free by the emit path via VCamZoomCurrentFactor).
static _Atomic double   gZoomFactor       = 1.0;
static _Atomic uint64_t gZoomObservations = 0;
// Priority of the setter that currently OWNS the factor value. The value is only updated by a
// setter whose priority is >= this; the first time a higher-priority setter fires it takes over.
// (Capture zoom setters fire on every change, so the owner never starves on a stale value.)
static _Atomic int      gZoomOwnerPrio    = 0;

double VCamZoomCurrentFactor(void) {
    double f = atomic_load_explicit(&gZoomFactor, memory_order_relaxed);
    if (!(f >= 1.0)) return 1.0;                 // NaN / <1 -> no crop (fail-open)
    if (f > VCAM_ZOOM_MAX) f = VCAM_ZOOM_MAX;
    return f;
}

// Record an observed factor from a setter of the given priority + name. The value is only adopted
// if prio >= the current owner's prio, so a low-priority setter (e.g. base=1.0) can never stomp the
// authoritative ISP/video factor. `name` is a stable C string literal (for logging only).
static void VCamZoomObserve(double factor, int prio, const char *name) {
    if (!(factor > 0.0) || isnan(factor)) return;    // ignore garbage
    if (factor < 1.0) factor = 1.0;
    if (factor > VCAM_ZOOM_MAX) factor = VCAM_ZOOM_MAX;

    int owner = atomic_load_explicit(&gZoomOwnerPrio, memory_order_relaxed);
    BOOL authoritative = (prio >= owner);
    if (authoritative) {
        if (prio > owner) atomic_store_explicit(&gZoomOwnerPrio, prio, memory_order_relaxed);
        atomic_store_explicit(&gZoomFactor, factor, memory_order_relaxed);
    }
    uint64_t n = atomic_fetch_add_explicit(&gZoomObservations, 1, memory_order_relaxed) + 1;
    // Log the first few observations and then sparsely — enough to prove WHICH setter tracks the
    // pinch (and whether the ranking is right) without spamming at zoom-ramp rate.
    if (n <= (uint64_t)(kZoomSelCount * 2) || (n % 120) == 0) {
        double f = factor; int p = prio, ow = authoritative ? prio : owner;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            VCamLog(@"zoom: %s=%.3f prio=%d %@ (owner=%d n=%llu)",
                    name, f, p, authoritative ? @"ADOPTED" : @"ignored", ow, n);
        });
    }
}

// Public entry (VCamZoom.h): explicit callers are treated as the top-priority source.
void VCamZoomSetFactor(double factor) {
    VCamZoomObserve(factor, 1000, "explicit");
}

// --- Generic setter trampolines -------------------------------------------------
// origs keyed by "ClassName#selectorName" so one replacement can serve many discovered setters and
// still find the right original to chain to. We look up BOTH the original IMP and the allowlist
// priority from the selector name inside the trampoline (so the two float/double trampolines cover
// every hooked selector without per-selector codegen).
static NSMutableDictionary<NSString *, NSValue *> *gZoomOrigs;

// Priority for a selector name, or 0 if not on the allowlist.
static int VCamZoomSelPriority(const char *n) {
    for (int i = 0; i < kZoomSelCount; i++)
        if (strcmp(n, kZoomSels[i].sel) == 0) return kZoomSels[i].prio;
    return 0;
}

static IMP VCamZoomOrig(id self, SEL _cmd) {
    // We hook the class that DECLARES the setter, but the trampoline may run on a SUBCLASS
    // instance (inherited IMP), so object_getClass(self) alone can miss the key and leave orig
    // NULL — which would drop the real zoom. Walk up the ancestry until a hooked key matches.
    NSString *selName = NSStringFromSelector(_cmd);
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c)) {
        NSValue *v = gZoomOrigs[[NSString stringWithFormat:@"%s#%@", class_getName(c), selName]];
        if (v) return (IMP)[v pointerValue];
    }
    return NULL;
}

// CGFloat/double-arg setter (arm64: the double is in d0, so this reads it correctly).
static void VCamZoomTrampD(id self, SEL _cmd, double factor) {
    VCamZoomObserve(factor, VCamZoomSelPriority(sel_getName(_cmd)), sel_getName(_cmd));
    IMP orig = VCamZoomOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, double))orig)(self, _cmd, factor);
}

// float-arg setter (arm64: the float is in s0; a distinct trampoline so the ABI matches).
static void VCamZoomTrampF(id self, SEL _cmd, float factor) {
    VCamZoomObserve((double)factor, VCamZoomSelPriority(sel_getName(_cmd)), sel_getName(_cmd));
    IMP orig = VCamZoomOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, float))orig)(self, _cmd, factor);
}

// Hook one allowlisted setter on class `c` (which must actually implement it). Chooses the
// float/double trampoline from the method's real ABI signature; skips non-scalar args.
static void VCamHookZoomSetter(Class c, SEL sel) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    char argType[16] = {0};
    char *at = method_copyArgumentType(m, 2);           // index 0=self,1=_cmd,2=first real arg
    if (at) { strncpy(argType, at, sizeof(argType) - 1); free(at); }
    IMP repl = NULL;
    if (argType[0] == 'd')      repl = (IMP)VCamZoomTrampD;   // double / CGFloat(arm64)
    else if (argType[0] == 'f') repl = (IMP)VCamZoomTrampF;   // float
    else {
        VCamLog(@"zoom: skip %s %@ (arg type '%s' not float/double)",
                class_getName(c), NSStringFromSelector(sel), argType);
        return;
    }
    IMP orig = NULL;
    MSHookMessageEx(c, sel, repl, &orig);
    if (orig) {
        NSString *key = [NSString stringWithFormat:@"%s#%@",
                         class_getName(c), NSStringFromSelector(sel)];
        gZoomOrigs[key] = [NSValue valueWithPointer:(const void *)orig];
        VCamLog(@"zoom: hooked setter %s %@ (arg '%s', prio %d)",
                class_getName(c), NSStringFromSelector(sel), argType,
                VCamZoomSelPriority(sel_getName(sel)));
    }
}

// Scan every loaded class ONCE; for each, hook whichever allowlisted setters it implements. Only
// classes in mediaserverd's address space are visible here, so unrelated framework zoom setters
// (UIKit/Maps/…) are naturally out of scope — and the allowlist keeps even capture-side matches
// to the six real factor setters.
static void VCamDiscoverZoomSetters(void) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;
    SEL sels[kZoomSelCount];
    for (int k = 0; k < kZoomSelCount; k++) sels[k] = sel_registerName(kZoomSels[k].sel);
    int hooked = 0;
    for (unsigned int i = 0; i < classCount; i++) {
        Class c = classes[i];
        if (!class_getName(c)) continue;
        // Copy this class's OWN method list once; hook whichever allowlisted setters it DECLARES
        // (matching the orig-key scheme, so we hook the class that owns the IMP, not an inherited one).
        unsigned int mc = 0;
        Method *methods = class_copyMethodList(c, &mc);
        if (!methods) continue;
        for (int k = 0; k < kZoomSelCount; k++) {
            for (unsigned int j = 0; j < mc; j++) {
                if (method_getName(methods[j]) == sels[k]) { VCamHookZoomSetter(c, sels[k]); hooked++; break; }
            }
        }
        free(methods);
    }
    free(classes);
    VCamLog(@"zoom: setter discovery complete (%d allowlisted setter(s) hooked across the runtime)",
            hooked);
    if (hooked == 0)
        VCamLog(@"zoom: NO allowlisted zoom setter found — follow-zoom stays at 1.0 (no crop). "
                 "Add the real setter from the class dump to kZoomSels.");
}

%ctor {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"";
        if (![proc isEqualToString:@"mediaserverd"]) return;    // mediaserverd only
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Media/vcam_nozoomprobe"]) {
            VCamLog(@"zoom: probe disabled by /var/mobile/Media/vcam_nozoomprobe");
            return;
        }
        gZoomOrigs = [NSMutableDictionary dictionary];
        // Discover on a background queue: objc_copyClassList over the whole runtime is not
        // something to run on the load thread's critical path, and nothing needs the setters
        // hooked before the first zoom gesture.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @try { VCamDiscoverZoomSetters(); }
            @catch (NSException *e) { VCamLog(@"zoom: discovery exception %@", e); }
        });
    }
}

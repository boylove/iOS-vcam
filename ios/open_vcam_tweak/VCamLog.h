#import <Foundation/Foundation.h>

// Shared logger. Declared with C linkage so both ObjC (.m) and ObjC++ (.mm/.xm)
// translation units resolve to the same symbol (the definition lives in Tweak.xm).
#ifdef __cplusplus
extern "C" {
#endif

void VCamLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

#ifdef __cplusplus
}
#endif

// Verbose, per-frame / diagnostic logging (probe, byte dumps, stats, produced
// counters). Off by default for release builds; set VCAM_DEBUG=1 in the Makefile
// (or with -DVCAM_DEBUG=1) to re-enable while debugging. Errors and one-time
// lifecycle events keep using VCamLog directly so they always show.
#ifndef VCAM_DEBUG
#define VCAM_DEBUG 0
#endif

#if VCAM_DEBUG
#define VCamDebugLog(...) VCamLog(__VA_ARGS__)
#else
#define VCamDebugLog(...) do { } while (0)
#endif

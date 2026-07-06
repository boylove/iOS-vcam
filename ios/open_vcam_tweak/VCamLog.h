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

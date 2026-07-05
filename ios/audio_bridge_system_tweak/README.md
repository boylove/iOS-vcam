# iOS-VCAM Audio Bridge System Hook

Phase 1 mediaserverd hook for AudioBridge System v0.1.

This package is intentionally separate from both:

- quarantined `com.iosvcam.audiobridge`
- deprecated direct-network `com.iosvcam.audiobridge.media-active`

## Package

- Package id: `com.iosvcam.audiobridge.system-hook`
- Dylib: `iOSVCAMAudioBridgeSystemHook.dylib`
- Filter: `com.apple.mediaserverd` / `mediaserverd`
- Disable flag: `/var/mobile/Library/Preferences/com.iosvcam.audiobridge.system-hook.disabled`
- Shared state path: `/var/mobile/Library/Caches/com.iosvcam.audiobridge.system/shared.bin`

## Phase 1 behavior

The hook installs an `AudioUnitRender` hook only inside mediaserverd. It calls the original render function and returns the original audio untouched.

It may read already-mapped shared metadata from the daemon, but the render callback must never do non-realtime work.

## Render callback rules

Allowed:

- call original `AudioUnitRender`;
- read cached pointers and atomic scalar fields;
- return original audio untouched.

Forbidden:

- TCP/client work;
- file open/map;
- allocation/free;
- locks/semaphores;
- Objective-C messages;
- logging;
- sleeps/retries;
- format conversion/resampling;
- unbounded loops.

## Phase 2

Audio replacement is intentionally not implemented here. It should be added only after Phase 1 stability is proven and must be behind strict explicit gates.

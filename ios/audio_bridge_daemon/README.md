# iOS-VCAM Audio Bridge Daemon

Phase 1 system-audio experiment for the `音频方案.txt` architecture.

This package is intentionally separate from the quarantined `com.iosvcam.audiobridge` package. Do not rename it to that package id.

## Package

- Package id: `com.iosvcam.audiobridge.daemon`
- Binary: `/var/jb/usr/libexec/iosvcam/iosvcam_audio_bridge_daemon`
- Shared state: `/var/mobile/Library/Caches/com.iosvcam.audiobridge.system/shared.bin`
- Default PC endpoint: `127.10.10.10:1936`

## Phase 1 behavior

The daemon owns all non-realtime work:

- opens the TCP link to the PC AudioBridge endpoint;
- parses the existing `IAF1` framed PCM protocol from `scripts/audio_bridge.py`;
- handles reconnect/backoff;
- writes counters, format metadata, and PCM bytes to shared memory.

It does **not** inject any target app and does **not** replace microphone audio by itself.

The bundled LaunchDaemon plist is disabled and `RunAtLoad` is false. Package install must not start services automatically. Any device-side start/load action is a manual Phase 1 test step and requires explicit approval.

## Safety rules

- Do not pair this with `com.iosvcam.audiobridge`.
- Do not add maintainer-script service starts, mediaserverd restarts, resprings, or device recovery changes.
- If the PC bridge is unavailable, the daemon keeps retrying and publishes fail-open status only.

# iOS-VCAM Audio Bridge Safe

Restricted test package for Scheme A virtual microphone work.

Safety differences from the quarantined `com.iosvcam.audiobridge` package:

- Package id is `com.iosvcam.audiobridge.safe`.
- Injection filter is restricted to TikTok bundle `com.zhiliaoapp.musically` / executable `TikTok`.
- It does not inject into Camera.app, SpringBoard, system media daemons, or AVFoundation globally.
- Runtime has CFPreferences/file disable controls under `com.iosvcam.audiobridge.safe`.
- If the bridge is unavailable or the target format is unsupported, it forwards the original microphone buffer.
- Version 0.3.9 mirrors/restores the same restricted dylib into `/usr/lib/TweakInject` and RootHide `pkgmirror` when RootHide is present, writes compatible filter plists, and avoids deleting the dylib during package upgrades.

Build:

```sh
make clean package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```

The PC bridge must be reachable at `127.10.10.10:1936` and should output PCM matching the target input format, typically 48 kHz S16LE mono. Launcher USB mode adds this reverse tunnel only when AudioBridge is enabled and the PC bridge is listening.

Do not install stale artifacts from `packages/` unless this source has been rebuilt and re-reviewed. This remains an experimental target-app virtual microphone path, not a global system Camera microphone replacement. Installation on the iPhone is manual only and requires explicit approval.

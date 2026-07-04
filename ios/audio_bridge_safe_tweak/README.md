# iOS-VCAM Audio Bridge Safe

Restricted test package for Scheme A virtual microphone work.

Safety differences from the quarantined `com.iosvcam.audiobridge` package:

- Package id is `com.iosvcam.audiobridge.safe`.
- Injection filter is restricted to TikTok bundle `com.zhiliaoapp.musically`.
- It does not inject into Camera.app, SpringBoard, mediaserverd, or AVFoundation globally.
- Runtime is disabled by default unless `/var/mobile/Library/Preferences/com.iosvcam.audiobridge.safe.plist` contains `Enabled=true`.
- If the bridge is unavailable or the target format is unsupported, it forwards the original microphone buffer.

Build:

```sh
make clean package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```

The PC bridge must be reachable at `127.10.10.10:1936` and should output PCM matching the target input format, typically 48 kHz S16LE mono.

# iOS-VCAM Audio Bridge Media Active

Experimental RootHide-compatible mediaserverd AudioBridge client.

This package is intentionally separate from the passive `com.iosvcam.audiobridge.media-probe` package and from the quarantined `com.iosvcam.audiobridge` package.

Safety rules:

- Package id is `com.iosvcam.audiobridge.media-active`.
- It targets `mediaserverd` only (`com.apple.mediaserverd` / executable `mediaserverd`).
- It connects to the PC AudioBridge at `127.10.10.10:1936` by default.
- Version 0.1.3 starts that TCP client at load time, mirrors logs to syslog, and accepts mediaserverd input renders observed on bus `0` or `1`.
- It hooks `AudioUnitRender` only inside `mediaserverd` and fails open to the original audio when unsupported.
- It does not inject into Camera.app, SpringBoard, TikTok, or AVFoundation globally.
- It only installs when the user manually installs the .deb; launcher code must not install, reload, or restart iPhone services automatically.
- Disable flag: `/var/mobile/Library/Preferences/com.iosvcam.audiobridge.media-active.disabled`.
- Optional preferences domain/file: `com.iosvcam.audiobridge.media-active` / `/var/mobile/Library/Preferences/com.iosvcam.audiobridge.media-active.plist`.

Expected PC-side success signal:

```text
client connected: <peer>
ffmpeg audio decode started for <peer>
```

Expected iPhone-side log markers:

```text
MEDIA_ACTIVE_LOADED
MEDIA_ACTIVE_CONNECTED connected to 127.10.10.10:1936
MEDIA_ACTIVE_READY AudioUnitRender hook installed
MEDIA_ACTIVE_REPLACED ...
```

If `MEDIA_ACTIVE_ASBD_UNSUPPORTED` appears, align the PC bridge sample rate/channels with the logged target ASBD before adding more hooks.

Build:

```sh
make clean package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```

On RootHide, convert the rootless input package with RootHide Patcher using AutoPatches before installing. Installation and reloads must be explicit, manual device-side actions.

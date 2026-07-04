# iOS-VCAM Audio Bridge Media Probe

Passive media-layer load probe for the next AudioBridge architecture.

This package is intentionally separate from `com.iosvcam.audiobridge.safe` and from the quarantined `com.iosvcam.audiobridge` package.

Safety rules:

- Package id is `com.iosvcam.audiobridge.media-probe`.
- It targets `mediaserverd` only.
- It does not hook audio APIs.
- It does not connect to the PC AudioBridge.
- It does not replace microphone audio.
- It only writes bounded load/probe logs.
- Disable flag: `/var/mobile/Library/Preferences/com.iosvcam.audiobridge.media-probe.disabled`.

The probe is used to prove whether a media-layer dylib can load under both RootHide-off and RootHide-on TikTok tests before any audio replacement code is introduced.

Build:

```sh
make clean package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```

On RootHide, convert the rootless input package with RootHide Patcher using AutoPatches before installing. Installation and reloads must be explicit, manual device-side actions.

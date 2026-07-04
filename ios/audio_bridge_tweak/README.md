# iOS-VCAM Audio Bridge Companion (Experimental)

This is a clean-room, audio-only Theos tweak scaffold for the iOS side of the planned OBS audio pipeline.

It is **not** DiCoy vendored into this repository. DiCoy was used only to identify the useful hook point: `AVCaptureAudioDataOutput` delegate callbacks. This companion keeps the existing `vcamera.dylib` video path unchanged and only attempts to replace microphone sample buffers when the target app uses compatible AVFoundation audio capture callbacks.

## Current status

Experimental source scaffold:

- Hooks `AVCaptureAudioDataOutput setSampleBufferDelegate:queue:`.
- Dynamically hooks delegate `captureOutput:didOutputSampleBuffer:fromConnection:` implementations.
- Connects to the Windows audio bridge at `127.10.10.10:1936`.
- Reads the protocol emitted by `scripts/audio_bridge.py`.
- Maintains a small PCM ring buffer.
- Injects signed 16-bit little-endian, interleaved PCM when the target app's audio format matches.
- Falls back to the original microphone buffer if the bridge is unavailable or the app uses an unsupported format.

Limitations:

- Only supports `AVCaptureAudioDataOutput`-style apps in this first version.
- Only supports interleaved 16-bit little-endian PCM, 1 or 2 channels.
- The bridge sample rate must match the target app capture sample rate.
- Does not handle WebRTC custom AudioUnit/AudioQueue stacks yet.
- RootHide is not supported by this scaffold until a dedicated RootHide build is added and tested.
- No automatic phone install is provided by the launcher; install manually only after reviewing the package.

## Build

Requires Theos and an iOS SDK on the build machine.

Rootless Dopamine-style package:

```sh
cd ios/audio_bridge_tweak
make clean package THEOS_PACKAGE_SCHEME=rootless
```

Rootful package, if you explicitly need it:

```sh
cd ios/audio_bridge_tweak
make clean package THEOS_PACKAGE_SCHEME=
```

The generated `.deb` normally appears under `ios/audio_bridge_tweak/packages/`.

## Runtime preferences

Optional plist path:

```text
/var/mobile/Library/Preferences/com.iosvcam.audiobridge.plist
```

Supported keys:

```plist
Enabled = true;
Host = "127.10.10.10";
Port = 1936;
VerboseLogging = false;
```

If the plist is absent, defaults are used.

## Expected PC-side setup

1. Start USB mode in the Windows launcher.
2. Enable the experimental Audio Bridge in the launcher configuration.
3. OBS publishes to `rtmp://localhost:1935/live` with stream key `srs`.
4. `scripts/audio_bridge.py` decodes RTMP audio and listens on `127.0.0.1:1936`.
5. The SSH tunnel exposes that audio stream to the iPhone as `127.10.10.10:1936`.

## Safety

Do not install this on a daily-use device without a recovery plan. It hooks audio capture callbacks inside AVFoundation-using apps. If a target app crashes, uninstall the package or disable it with the preference plist, then restart the affected app or `mediaserverd`.

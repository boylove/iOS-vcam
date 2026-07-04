# Audio Bridge and DiCoy Integration Notes

## Do not install the iOS audio companion package

The experimental package `com.iosvcam.audiobridge` is **unsafe for this project state**. On the user's Dopamine iOS 16.1.2 device, installing `com.iosvcam.audiobridge_0.1.0_iphoneos-arm64.deb` affected the jailbreak/camera environment badly enough that the user removed the jailbreak environment, re-jailbroke, and reinstalled only `iosvcam_base_127_10_10_10.deb`.

Do **not** recommend, build, install, or test that package again unless a future implementation is redesigned and explicitly approved.

## Current supported state

The stable iOS-VCAM path is video-only from the target app's perspective:

```text
OBS -> SRS RTMP on Windows -> SSH reverse tunnel -> iPhone vcamera video path
```

That path may carry RTMP audio at the transport layer, but the existing `vcamera.dylib` does not provide a safe virtual microphone implementation.

## DiCoy findings retained for research only

DiCoy remains useful as a research reference because it demonstrates a possible microphone hook point:

1. Hook `AVCaptureAudioDataOutput`.
2. Intercept `setSampleBufferDelegate:queue:`.
3. Hook `captureOutput:didOutputSampleBuffer:fromConnection:`.
4. Create replacement `CMSampleBuffer` audio.

However:

- DiCoy is beta/in-development.
- Its working path is media-file injection, not live OBS RTMP audio.
- It only works in some apps.
- Copying GPL DiCoy code has license implications.
- The attempted clean-room `com.iosvcam.audiobridge` companion proved unsafe on the user's device.

## Experimental safe AudioBridge status

`scripts/audio_bridge.py` can decode OBS/SRS audio to framed PCM on `127.0.0.1:1936`. When launcher AudioBridge is enabled and starts successfully, Option [U] adds an optional SSH reverse tunnel:

```text
127.10.10.10:1936 -> PC 127.0.0.1:1936
```

This is only for the experimental `com.iosvcam.audiobridge.safe` target-app path. Version 0.3.7 keeps the normal rootless install path and mirrors the same restricted dylib into RootHide's `/usr/lib/TweakInject` with an XML filter plist when that environment is present. It is not a global system microphone replacement, and system Camera may still record the real iPhone microphone.

## Safe recommendation

For stable use, keep the supported setup to:

- `iosvcam_base_127_10_10_10.deb`
- USB reverse tunnel for ports `80` and `1935`
- OBS video over RTMP

For explicit virtual microphone experiments, use only the restricted `com.iosvcam.audiobridge.safe` path with AudioBridge enabled so port `1936` is tunneled. The Safe AudioBridge package must still be installed manually after explicit approval. Do not install the quarantined `com.iosvcam.audiobridge` package again.

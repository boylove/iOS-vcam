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

## AudioBridge System v0.1 status

`scripts/audio_bridge.py` can decode OBS/SRS audio to framed PCM on `127.0.0.1:1936`. When launcher AudioBridge is enabled and starts successfully, Option [U] adds an optional SSH reverse tunnel:

```text
127.10.10.10:1936 -> PC 127.0.0.1:1936
```

The new system-audio route is intentionally split into two packages:

- `com.iosvcam.audiobridge.daemon` owns TCP client work, `IAF1` parsing, reconnects, buffering, and shared-state counters.
- `com.iosvcam.audiobridge.system-hook` targets `mediaserverd` but Phase 1 is passive: it reads already-mapped shared state and always returns original audio untouched.

This replaces the old direction of putting network/reconnect/buffering directly inside the mediaserverd dylib. The old `com.iosvcam.audiobridge.media-active` package remains a high-risk experiment and should not be the main path for further stability work. The passive `com.iosvcam.audiobridge.media-probe` still only logs load state and never connects to `1936`.

## Phase plan

### Phase 1: probe only, no replacement

Expected behavior:

- PC bridge listens on `127.0.0.1:1936`.
- USB mode tunnels `127.10.10.10:1936` to the PC bridge.
- The iPhone daemon can consume `IAF1` frames and publish shared counters.
- The mediaserverd system hook remains realtime-safe and does not write microphone buffers.
- Camera preview/recording stability is the only success criterion.

### Phase 2: replacement behind gates only

Do not enable replacement until Phase 1 is stable. Replacement must require real input render, exact supported Linear PCM format, fresh daemon state, enough buffered frames, watchdog health, and an explicit enable flag. Unsupported or stale states must fail open immediately.

## Safe recommendation

For stable use, keep the supported setup to:

- `iosvcam_base_127_10_10_10.deb`
- USB reverse tunnel for ports `80` and `1935`
- OBS video over RTMP

For explicit virtual microphone experiments, use only reviewed iOS-VCAM packages. `com.iosvcam.audiobridge.daemon` and `com.iosvcam.audiobridge.system-hook` are manual Phase 1 system-audio artifacts; installing or starting them on the iPhone requires explicit approval. All iPhone packages must still be installed manually after approval. Do not install the quarantined `com.iosvcam.audiobridge` package again.

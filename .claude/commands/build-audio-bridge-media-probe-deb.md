# Build AudioBridge Media Probe .deb via GitHub Actions

Use this command when the user wants to build the passive media-layer probe package `com.iosvcam.audiobridge.media-probe` from Windows.

## Default build

From the repository root:

```powershell
python scripts/github_build_audio_bridge_media_probe_deb.py
```

The wrapper defaults to:

- GitHub account/remote: `boylove`
- Actions repo: `boylove/iOS-vcam`
- Branch: current branch, typically `build/audio-bridge-tweak`
- Workflow: `.github/workflows/build-audio-bridge-media-probe-tweak.yml`
- Artifact: `iosvcam-audio-bridge-media-probe-rootless-deb`
- Download directory: `ios/audio_bridge_media_probe_tweak/packages/`

## Include local media probe changes

```powershell
python scripts/github_build_audio_bridge_media_probe_deb.py --commit-changes
```

This commits only the media-probe build inputs, pushes to `boylove`, triggers the workflow, watches it, and downloads the `.deb` artifact.

## Important safety note

The media probe is passive. It should only log whether the media-layer dylib loads into `mediaserverd`; it does **not** replace microphone audio.

The wrapper only builds and downloads the `.deb`. It does **not** install anything on the iPhone. Installation, RootHide Patcher conversion, and any reloads still require explicit user approval.

The unsafe package `com.iosvcam.audiobridge` remains quarantined. Do not install or recommend it.

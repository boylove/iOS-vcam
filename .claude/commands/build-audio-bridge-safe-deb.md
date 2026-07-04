# Build Safe AudioBridge .deb via GitHub Actions

Use this command when the user wants to rebuild the restricted TikTok-only `com.iosvcam.audiobridge.safe` package from a Windows machine.

## Default build

From the repository root:

```powershell
python scripts/github_build_audio_bridge_safe_deb.py
```

The wrapper defaults to:

- GitHub account/remote: `boylove`
- Actions repo: `boylove/iOS-vcam`
- Branch: current branch, typically `build/audio-bridge-tweak`
- Workflow: `.github/workflows/build-audio-bridge-safe-tweak.yml`
- Artifact: `iosvcam-audio-bridge-safe-rootless-roothide-deb`
- Download directory: `ios/audio_bridge_safe_tweak/packages/`

## Include local safe tweak changes

If `ios/audio_bridge_safe_tweak/**`, the workflow, or the wrapper changed and should be included in the build:

```powershell
python scripts/github_build_audio_bridge_safe_deb.py --commit-changes
```

This commits only the safe AudioBridge build inputs, pushes to `boylove`, triggers the workflow, watches it, and downloads the `.deb` artifact.

## Authentication

The script locates `gh.exe` automatically, including the portable path:

```text
D:\Temp\gh-cli-portable\bin\gh.exe
```

If GitHub CLI is not authenticated, run:

```powershell
& "D:\Temp\gh-cli-portable\bin\gh.exe" auth login -h github.com -p https -w
```

## Important safety note

The wrapper only builds and downloads the `.deb`. It does **not** install anything on the iPhone. Installation still requires explicit user approval.

The unsafe package `com.iosvcam.audiobridge` remains quarantined. Use only `com.iosvcam.audiobridge.safe` 0.3.9+ for TikTok-only safe-audio experiments. Version 0.3.9 keeps the normal rootless install path, adds guarded RootHide `TweakInject` and `pkgmirror` support, writes compatible RootHide filters, and avoids deleting the dylib during upgrades.

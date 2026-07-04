# Build Audio Bridge .deb via GitHub Actions

Use this command when the user wants to rebuild the experimental iOS-VCAM Audio Bridge companion tweak `.deb` using GitHub Actions, especially from a Windows-only machine.

## What to do

Run the reusable PowerShell wrapper from the repository root:

```powershell
pwsh -ExecutionPolicy Bypass -File scripts/github_build_audio_bridge_deb.ps1
```

If there are local changes to the workflow or `ios/audio_bridge_tweak/` that should be included in the build, run:

```powershell
pwsh -ExecutionPolicy Bypass -File scripts/github_build_audio_bridge_deb.ps1 -CommitChanges
```

## Expected behavior

The wrapper will:

1. Locate or download GitHub CLI.
2. Verify `gh auth status`.
3. Derive the authenticated GitHub account and fork repo.
4. Create/reuse a fork of `LiuSky/iOS-vcam` if needed.
5. Add/update a `build-fork` git remote.
6. Push the current branch to the fork.
7. Trigger `.github/workflows/build-audio-bridge-tweak.yml`.
8. Watch the Actions run.
9. Download the `.deb` artifact into `ios/audio_bridge_tweak/packages/`.

## If authentication is missing

Ask the user to run this in their local PowerShell terminal:

```powershell
& "D:\Temp\gh-cli-portable\bin\gh.exe" auth login -h github.com -p https -w
```

If the portable `gh.exe` path is different or absent, the wrapper can download it automatically; rerun the wrapper after login.

## Success output

The final `.deb` should appear at a path like:

```text
ios/audio_bridge_tweak/packages/com.iosvcam.audiobridge_0.1.0_iphoneos-arm64.deb
```

Do not install the package automatically. The user should explicitly approve any iPhone install/respring step.

# Quick validation test for iOS-VCAM-Launcher.ps1
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "             iOS-VCAM LAUNCHER - VALIDATION TEST" -ForegroundColor Yellow
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$errors = @()
$warnings = @()
$success = @()

function Get-FileText {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return Get-Content -Path $Path -Raw -ErrorAction SilentlyContinue
}

# Test 1: Check PS1 exists and parses
Write-Host "[TEST 1] Checking PowerShell launcher script..." -ForegroundColor Yellow
$launcherPath = ".\iOS-VCAM-Launcher.ps1"
if (Test-Path $launcherPath) {
    $success += "✓ PowerShell launcher exists (iOS-VCAM-Launcher.ps1)"
    $scriptSize = (Get-Item $launcherPath).Length / 1KB
    $success += "✓ Launcher script size: $([math]::Round($scriptSize, 2)) KB"

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $launcherPath).Path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -eq 0) {
        $success += "✓ Launcher PowerShell syntax parses successfully"
    } else {
        $errors += "✗ Launcher PowerShell syntax errors: $($parseErrors.Count)"
        foreach ($parseError in $parseErrors) {
            $errors += "  - $parseError"
        }
    }
} else {
    $errors += "✗ PowerShell launcher not found (iOS-VCAM-Launcher.ps1)"
}
Write-Host ""

# Test 2: Check launcher entrypoints
Write-Host "[TEST 2] Checking launcher entrypoints..." -ForegroundColor Yellow
$batPath = ".\iOS-VCAM-Launcher.bat"
if (Test-Path $batPath) {
    $success += "✓ Double-click BAT wrapper exists (iOS-VCAM-Launcher.bat)"
    $batContent = Get-FileText $batPath
    if ($batContent -match 'powershell.*-ExecutionPolicy\s+Bypass.*-File.*iOS-VCAM-Launcher\.ps1') {
        $success += "✓ BAT wrapper launches the canonical PS1 with ExecutionPolicy Bypass"
    } else {
        $errors += "✗ BAT wrapper does not launch iOS-VCAM-Launcher.ps1 with ExecutionPolicy Bypass"
    }
} else {
    $errors += "✗ Double-click BAT wrapper not found (iOS-VCAM-Launcher.bat)"
}

$duplicateLaunchers = @(".\iOS-VCAM-Launcher.exe", ".\iOS-VCAM-Launcher4.2.exe")
$remainingDuplicates = @($duplicateLaunchers | Where-Object { Test-Path $_ })
if ($remainingDuplicates.Count -eq 0) {
    $success += "✓ Stale EXE launchers are absent"
} else {
    $errors += "✗ Stale EXE launcher files still present: $($remainingDuplicates -join ', ')"
}
Write-Host ""

# Test 3: Check config directory structure
Write-Host "[TEST 3] Checking configuration files..." -ForegroundColor Yellow
if (Test-Path ".\config\active") {
    $success += "✓ Config directory exists (config\active)"
    $configs = Get-ChildItem ".\config\active\srs_iphone*.conf" -ErrorAction SilentlyContinue
    if ($configs.Count -gt 0) {
        $success += "✓ Found $($configs.Count) iPhone-optimized configs"
    } else {
        $errors += "✗ No iPhone configs found in config\active"
    }
} else {
    $errors += "✗ Config directory not found (config\active)"
}
Write-Host ""

# Test 4: Check SRS server binary
Write-Host "[TEST 4] Checking SRS server binary..." -ForegroundColor Yellow
if (Test-Path ".\objs\srs.exe") {
    $success += "✓ SRS binary exists (objs\srs.exe)"
    $srsSize = (Get-Item ".\objs\srs.exe").Length / 1MB
    $success += "✓ SRS size: $([math]::Round($srsSize, 2)) MB"
} else {
    $errors += "✗ SRS binary not found (objs\srs.exe)"
}
Write-Host ""

# Test 5: Check Flask authentication server
Write-Host "[TEST 5] Checking Flask authentication server..." -ForegroundColor Yellow
if (Test-Path ".\server.py") {
    $success += "✓ Flask server exists (server.py)"
} else {
    $warnings += "⚠ Flask server not found (server.py)"
}
Write-Host ""

# Test 6: Check icon file
Write-Host "[TEST 6] Checking icon file..." -ForegroundColor Yellow
if (Test-Path ".\iOS-VCAM.ico") {
    $success += "✓ Icon file exists (iOS-VCAM.ico)"
} else {
    $warnings += "⚠ Icon file not found (iOS-VCAM.ico)"
}
Write-Host ""

# Test 7: Check specific config files referenced in code
Write-Host "[TEST 7] Checking referenced configuration files..." -ForegroundColor Yellow
$requiredConfigs = @(
    "config\active\srs_iphone_ultra_smooth_dynamic.conf",
    "config\active\srs_iphone_ultra_smooth.conf",
    "config\active\srs_iphone_optimized_smooth.conf",
    "config\active\srs_usb_smooth_playback.conf"
)

foreach ($config in $requiredConfigs) {
    if (Test-Path $config) {
        $success += "✓ Found: $config"
    } else {
        $errors += "✗ Missing: $config"
    }
}
Write-Host ""

# Test 8: Check PS1-only and audio bridge safety invariants
Write-Host "[TEST 8] Checking safety invariants..." -ForegroundColor Yellow
$safeTweakFiles = @(
    "ios\audio_bridge_safe_tweak\control",
    "ios\audio_bridge_safe_tweak\iOSVCAMAudioBridgeSafe.plist",
    "ios\audio_bridge_safe_tweak\layout\DEBIAN\postinst",
    "ios\audio_bridge_safe_tweak\layout\DEBIAN\postrm",
    "ios\audio_bridge_safe_tweak\Tweak.x"
)
foreach ($file in $safeTweakFiles) {
    $text = Get-FileText $file
    if ($null -eq $text) {
        $warnings += "⚠ Safe audio bridge file not found: $file"
        continue
    }
    if ($text -match 'com\.apple\.mediaserverd|\bmediaserverd\b') {
        $errors += "✗ Safe audio bridge must not target mediaserverd: $file"
    }
    if ($text -match 'com\.apple\.camera|Camera\.app|com\.apple\.springboard|SpringBoard') {
        $errors += "✗ Safe audio bridge must not target Camera.app or SpringBoard: $file"
    }
    if ($text -match 'Package:\s*com\.iosvcam\.audiobridge\s*(?:$|\r?\n)') {
        $errors += "✗ Safe audio bridge must not use quarantined package id: $file"
    }
}
if (-not ($errors | Where-Object { $_ -match 'mediaserverd' })) {
    $success += "✓ Safe audio bridge sources do not target mediaserverd"
}
if (-not ($errors | Where-Object { $_ -match 'Camera\.app|SpringBoard' })) {
    $success += "✓ Safe audio bridge sources do not target Camera.app or SpringBoard"
}
if (-not ($errors | Where-Object { $_ -match 'quarantined package id' })) {
    $success += "✓ Safe audio bridge keeps the safe package id"
}

$postinstText = Get-FileText "ios\audio_bridge_safe_tweak\layout\DEBIAN\postinst"
$postrmText = Get-FileText "ios\audio_bridge_safe_tweak\layout\DEBIAN\postrm"
if ($postinstText -and $postinstText -match '/usr/lib/TweakInject') {
    if ($postinstText -notmatch '/var/jb/Library/MobileSubstrate/DynamicLibraries' -or
        $postinstText -notmatch 'ROOTLESS_DYLIB' -or
        $postinstText -notmatch 'BACKUP_DYLIB' -or
        $postinstText -notmatch 'PKGMIRROR_DIR' -or
        $postinstText -notmatch 'cp\s+-f' -or
        $postinstText -notmatch '<!DOCTYPE plist' -or
        $postinstText -notmatch 'write_filter_openstep' -or
        $postinstText -notmatch '<string>TikTok</string>') {
        $errors += "✗ Safe AudioBridge RootHide postinst must mirror rootless/backup/pkgmirror dylib and write XML/OpenStep filters"
    } else {
        $success += "✓ Safe AudioBridge RootHide postinst mirrors rootless/backup/pkgmirror dylib and writes XML/OpenStep filters"
    }
}
if ($postrmText -and (
    $postrmText -notmatch 'case "\$1"' -or
    $postrmText -notmatch 'remove\|purge' -or
    $postrmText -notmatch 'iOSVCAMAudioBridgeSafe\.dylib\.roothidepatch' -or
    $postrmText -notmatch 'PKGMIRROR_DIR' -or
    $postrmText -notmatch 'iOSVCAMAudioBridgeSafe\.dylib' -or
    $postrmText -notmatch 'iOSVCAMAudioBridgeSafe\.plist')) {
    $errors += "✗ Safe AudioBridge postrm must clean RootHide mirror files only on remove/purge"
} elseif ($postrmText) {
    $success += "✓ Safe AudioBridge postrm cleans RootHide mirror files only on remove/purge"
}

$mediaProbeFiles = @(
    "ios\audio_bridge_media_probe_tweak\control",
    "ios\audio_bridge_media_probe_tweak\iOSVCAMAudioBridgeMediaProbe.plist",
    "ios\audio_bridge_media_probe_tweak\layout\DEBIAN\postinst",
    "ios\audio_bridge_media_probe_tweak\layout\DEBIAN\postrm",
    "ios\audio_bridge_media_probe_tweak\Tweak.x"
)
foreach ($file in $mediaProbeFiles) {
    $text = Get-FileText $file
    if ($null -eq $text) {
        $warnings += "⚠ Media probe file not found: $file"
        continue
    }
    if ($text -match 'Package:\s*com\.iosvcam\.audiobridge\s*(?:$|\r?\n)') {
        $errors += "✗ Media probe must not use quarantined package id: $file"
    }
}
$mediaProbeControl = Get-FileText "ios\audio_bridge_media_probe_tweak\control"
$mediaProbeTweak = Get-FileText "ios\audio_bridge_media_probe_tweak\Tweak.x"
$mediaProbePostinst = Get-FileText "ios\audio_bridge_media_probe_tweak\layout\DEBIAN\postinst"
$mediaProbePostrm = Get-FileText "ios\audio_bridge_media_probe_tweak\layout\DEBIAN\postrm"
if ($mediaProbeControl -and $mediaProbeControl -notmatch 'Package:\s*com\.iosvcam\.audiobridge\.media-probe') {
    $errors += "✗ Media probe package id must be com.iosvcam.audiobridge.media-probe"
}
if ($mediaProbeTweak -and (
    $mediaProbeTweak -notmatch 'MEDIA_PROBE_LOADED' -or
    $mediaProbeTweak -notmatch 'MEDIA_PROBE_PASSIVE' -or
    $mediaProbeTweak -notmatch 'media-probe\.disabled' -or
    $mediaProbeTweak -match 'IAF1|AudioUnitRender|AVCaptureAudioDataOutput|connected to %@:%d')) {
    $errors += "✗ Media probe must be passive and include load/disable markers without audio replacement hooks"
} elseif ($mediaProbeTweak) {
    $success += "✓ Media probe is passive and includes load/disable markers"
}
if ($mediaProbePostinst -and (
    $mediaProbePostinst -notmatch '/usr/lib/TweakInject' -or
    $mediaProbePostinst -notmatch '/usr/lib/DynamicPatches/AutoPatches\.dylib' -or
    $mediaProbePostinst -notmatch 'BACKUP_DYLIB' -or
    $mediaProbePostinst -notmatch 'PKGMIRROR_DIR' -or
    $mediaProbePostinst -notmatch 'com\.apple\.mediaserverd' -or
    $mediaProbePostinst -notmatch 'write_filter_openstep')) {
    $errors += "✗ Media probe postinst must support TweakInject/AutoPatches/pkgmirror mediaserverd probing"
} elseif ($mediaProbePostinst) {
    $success += "✓ Media probe postinst supports TweakInject/AutoPatches/pkgmirror mediaserverd probing"
}
if ($mediaProbePostrm -and (
    $mediaProbePostrm -notmatch 'case "\$1"' -or
    $mediaProbePostrm -notmatch 'remove\|purge' -or
    $mediaProbePostrm -notmatch 'iOSVCAMAudioBridgeMediaProbe\.dylib\.roothidepatch' -or
    $mediaProbePostrm -notmatch 'PKGMIRROR_DIR')) {
    $errors += "✗ Media probe postrm must clean only media probe RootHide files on remove/purge"
} elseif ($mediaProbePostrm) {
    $success += "✓ Media probe postrm cleans only media probe RootHide files on remove/purge"
}

$mediaActiveFiles = @(
    "ios\audio_bridge_media_active_tweak\control",
    "ios\audio_bridge_media_active_tweak\iOSVCAMAudioBridgeMediaActive.plist",
    "ios\audio_bridge_media_active_tweak\layout\DEBIAN\postinst",
    "ios\audio_bridge_media_active_tweak\layout\DEBIAN\postrm",
    "ios\audio_bridge_media_active_tweak\Tweak.x"
)
foreach ($file in $mediaActiveFiles) {
    $text = Get-FileText $file
    if ($null -eq $text) {
        $errors += "✗ Media-active file not found: $file"
        continue
    }
    if ($text -match 'Package:\s*com\.iosvcam\.audiobridge\s*(?:$|\r?\n)') {
        $errors += "✗ Media-active must not use quarantined package id: $file"
    }
    if ($text -match 'com\.apple\.camera|Camera\.app|com\.apple\.springboard|SpringBoard|com\.zhiliaoapp\.musically|\bTikTok\b') {
        $errors += "✗ Media-active must not target Camera.app, SpringBoard, or TikTok: $file"
    }
}
$mediaActiveControl = Get-FileText "ios\audio_bridge_media_active_tweak\control"
$mediaActiveTweak = Get-FileText "ios\audio_bridge_media_active_tweak\Tweak.x"
$mediaActivePostinst = Get-FileText "ios\audio_bridge_media_active_tweak\layout\DEBIAN\postinst"
$mediaActivePostrm = Get-FileText "ios\audio_bridge_media_active_tweak\layout\DEBIAN\postrm"
if ($mediaActiveControl -and $mediaActiveControl -notmatch 'Package:\s*com\.iosvcam\.audiobridge\.media-active') {
    $errors += "✗ Media-active package id must be com.iosvcam.audiobridge.media-active"
}
if ($mediaActiveTweak -and (
    $mediaActiveTweak -notmatch 'MEDIA_ACTIVE_LOADED' -or
    $mediaActiveTweak -notmatch 'MEDIA_ACTIVE_READY' -or
    $mediaActiveTweak -notmatch 'media-active\.disabled' -or
    $mediaActiveTweak -notmatch 'IAF1' -or
    $mediaActiveTweak -notmatch 'AudioUnitRender' -or
    $mediaActiveTweak -notmatch '127\.10\.10\.10')) {
    $errors += "✗ Media-active must include load/ready/disable markers, IAF1 client, AudioUnitRender hook, and default tunnel host"
} elseif ($mediaActiveTweak) {
    $success += "✓ Media-active includes active AudioBridge markers and disable controls"
}
if ($mediaActivePostinst -and (
    $mediaActivePostinst -notmatch '/usr/lib/TweakInject' -or
    $mediaActivePostinst -notmatch '/usr/lib/DynamicPatches/AutoPatches\.dylib' -or
    $mediaActivePostinst -notmatch 'BACKUP_DYLIB' -or
    $mediaActivePostinst -notmatch 'PKGMIRROR_DIR' -or
    $mediaActivePostinst -notmatch 'com\.apple\.mediaserverd' -or
    $mediaActivePostinst -notmatch 'write_filter_openstep')) {
    $errors += "✗ Media-active postinst must support TweakInject/AutoPatches/pkgmirror mediaserverd active loading"
} elseif ($mediaActivePostinst) {
    $success += "✓ Media-active postinst supports TweakInject/AutoPatches/pkgmirror mediaserverd active loading"
}
if ($mediaActivePostrm -and (
    $mediaActivePostrm -notmatch 'case "\$1"' -or
    $mediaActivePostrm -notmatch 'remove\|purge' -or
    $mediaActivePostrm -notmatch 'iOSVCAMAudioBridgeMediaActive\.dylib\.roothidepatch' -or
    $mediaActivePostrm -notmatch 'PKGMIRROR_DIR')) {
    $errors += "✗ Media-active postrm must clean only media-active RootHide files on remove/purge"
} elseif ($mediaActivePostrm) {
    $success += "✓ Media-active postrm cleans only media-active RootHide files on remove/purge"
}

$audioDaemonFiles = @(
    "ios\audio_bridge_common\AudioBridgeShared.h",
    "ios\audio_bridge_daemon\control",
    "ios\audio_bridge_daemon\Makefile",
    "ios\audio_bridge_daemon\audio_bridge_daemon.c",
    "ios\audio_bridge_daemon\layout\DEBIAN\postinst",
    "ios\audio_bridge_daemon\layout\DEBIAN\postrm",
    "ios\audio_bridge_daemon\layout\Library\LaunchDaemons\com.iosvcam.audiobridge.daemon.plist"
)
foreach ($file in $audioDaemonFiles) {
    if (-not (Test-Path $file)) {
        $errors += "✗ Audio daemon file not found: $file"
    }
}
$audioDaemonControl = Get-FileText "ios\audio_bridge_daemon\control"
$audioDaemonSource = Get-FileText "ios\audio_bridge_daemon\audio_bridge_daemon.c"
$audioDaemonPostinst = Get-FileText "ios\audio_bridge_daemon\layout\DEBIAN\postinst"
$audioDaemonPostrm = Get-FileText "ios\audio_bridge_daemon\layout\DEBIAN\postrm"
$audioDaemonLaunchd = Get-FileText "ios\audio_bridge_daemon\layout\Library\LaunchDaemons\com.iosvcam.audiobridge.daemon.plist"
if ($audioDaemonControl -and $audioDaemonControl -notmatch 'Package:\s*com\.iosvcam\.audiobridge\.daemon') {
    $errors += "✗ Audio daemon package id must be com.iosvcam.audiobridge.daemon"
}
if ($audioDaemonSource -and (
    $audioDaemonSource -notmatch 'AUDIO_DAEMON_READY' -or
    $audioDaemonSource -notmatch 'IAF1' -or
    $audioDaemonSource -notmatch '127\.10\.10\.10' -or
    $audioDaemonSource -notmatch 'IVCAM_AB_HOOK_PASSIVE')) {
    $errors += "✗ Audio daemon must include passive shared-state markers, IAF1 parsing, and default tunnel host"
} elseif ($audioDaemonSource) {
    $success += "✓ Audio daemon includes passive shared-state and IAF1 bridge markers"
}
if ($audioDaemonLaunchd -and (
    $audioDaemonLaunchd -notmatch '<key>Disabled</key>\s*<true/>' -or
    $audioDaemonLaunchd -notmatch '<key>RunAtLoad</key>\s*<false/>')) {
    $errors += "✗ Audio daemon LaunchDaemon must be disabled and not RunAtLoad by default"
} elseif ($audioDaemonLaunchd) {
    $success += "✓ Audio daemon LaunchDaemon is disabled by default"
}
if (($audioDaemonPostinst + "`n" + $audioDaemonPostrm + "`n" + $audioDaemonLaunchd) -match '\blaunchctl\b|\bkillall\b|\bsbreload\b|\brespring\b|/etc/ssh/sshd_config|ifconfig\s+lo0\s+alias') {
    $errors += "✗ Audio daemon package must not auto-load services, restart processes, respring, or change device recovery settings"
} elseif ($audioDaemonPostinst -or $audioDaemonPostrm -or $audioDaemonLaunchd) {
    $success += "✓ Audio daemon package avoids automatic device-side service/recovery changes"
}

$systemHookFiles = @(
    "ios\audio_bridge_system_tweak\control",
    "ios\audio_bridge_system_tweak\Makefile",
    "ios\audio_bridge_system_tweak\Tweak.x",
    "ios\audio_bridge_system_tweak\iOSVCAMAudioBridgeSystemHook.plist",
    "ios\audio_bridge_system_tweak\layout\DEBIAN\postinst",
    "ios\audio_bridge_system_tweak\layout\DEBIAN\postrm"
)
foreach ($file in $systemHookFiles) {
    if (-not (Test-Path $file)) {
        $errors += "✗ System hook file not found: $file"
    }
}
$systemHookControl = Get-FileText "ios\audio_bridge_system_tweak\control"
$systemHookTweak = Get-FileText "ios\audio_bridge_system_tweak\Tweak.x"
$systemHookPostinst = Get-FileText "ios\audio_bridge_system_tweak\layout\DEBIAN\postinst"
$systemHookPostrm = Get-FileText "ios\audio_bridge_system_tweak\layout\DEBIAN\postrm"
if ($systemHookControl -and $systemHookControl -notmatch 'Package:\s*com\.iosvcam\.audiobridge\.system-hook') {
    $errors += "✗ System hook package id must be com.iosvcam.audiobridge.system-hook"
}
if ($systemHookTweak -and (
    $systemHookTweak -notmatch 'AUDIO_SYSTEM_HOOK_LOADED' -or
    $systemHookTweak -notmatch 'AUDIO_SYSTEM_HOOK_READY' -or
    $systemHookTweak -notmatch 'AUDIO_SYSTEM_HOOK_PASSIVE' -or
    $systemHookTweak -notmatch 'system-hook\.disabled' -or
    $systemHookTweak -notmatch 'AUDIO_SYSTEM_HOOK_PHASE2' -or
    $systemHookTweak -notmatch 'AudioUnitRender')) {
    $errors += "✗ System hook must include load/ready/passive/disable markers, Phase 2 marker, and AudioUnitRender hook"
} elseif ($systemHookTweak) {
    $success += "✓ System hook includes shared-ring AudioUnitRender markers"
}
if ($systemHookTweak -and $systemHookTweak -match '\b(socket|connect|recv|send)\s*\(|arpa/inet|sys/socket|MEDIA_ACTIVE_REPLACED|connected to %@:%d') {
    $errors += "✗ System hook Phase 1 must not contain direct network client code or active replacement markers"
} elseif ($systemHookTweak) {
    $success += "✓ System hook Phase 1 source has no direct network client or active replacement markers"
}
if ($systemHookTweak -and $systemHookTweak -match 'com\.apple\.camera|Camera\.app|com\.apple\.springboard|SpringBoard|com\.zhiliaoapp\.musically|\bTikTok\b') {
    $errors += "✗ System hook must not target Camera.app, SpringBoard, or TikTok"
}
if ($systemHookPostinst -and (
    $systemHookPostinst -notmatch '/usr/lib/TweakInject' -or
    $systemHookPostinst -notmatch '/usr/lib/DynamicPatches/AutoPatches\.dylib' -or
    $systemHookPostinst -notmatch 'BACKUP_DYLIB' -or
    $systemHookPostinst -notmatch 'PKGMIRROR_DIR' -or
    $systemHookPostinst -notmatch 'com\.apple\.mediaserverd' -or
    $systemHookPostinst -notmatch 'write_filter_openstep')) {
    $errors += "✗ System hook postinst must support TweakInject/AutoPatches/pkgmirror mediaserverd probing"
} elseif ($systemHookPostinst) {
    $success += "✓ System hook postinst supports TweakInject/AutoPatches/pkgmirror mediaserverd probing"
}
if ($systemHookPostrm -and (
    $systemHookPostrm -notmatch 'case "\$1"' -or
    $systemHookPostrm -notmatch 'remove\|purge' -or
    $systemHookPostrm -notmatch 'iOSVCAMAudioBridgeSystemHook\.dylib\.roothidepatch' -or
    $systemHookPostrm -notmatch 'PKGMIRROR_DIR')) {
    $errors += "✗ System hook postrm must clean only system-hook RootHide files on remove/purge"
} elseif ($systemHookPostrm) {
    $success += "✓ System hook postrm cleans only system-hook RootHide files on remove/purge"
}

$systemBuildScripts = @(
    "scripts\github_build_audio_bridge_daemon_deb.py",
    "scripts\github_build_audio_bridge_system_hook_deb.py"
)
foreach ($file in $systemBuildScripts) {
    $text = Get-FileText $file
    if ($null -eq $text) {
        $errors += "✗ AudioBridge system build wrapper not found: $file"
        continue
    }
    if ($text -match 'dpkg\s+-i|\blaunchctl\b|\bkillall\b|\bsbreload\b|\brespring\b|/etc/ssh/sshd_config|ifconfig\s+lo0\s+alias') {
        $errors += "✗ AudioBridge system build wrapper must not install or mutate the iPhone: $file"
    }
}

$testFiles = Get-ChildItem ".\tests" -Filter "*.ps1" -ErrorAction SilentlyContinue
$noExitFlag = '-' + 'NoExit'
$noExitMatches = @()
foreach ($file in $testFiles) {
    $text = Get-FileText $file.FullName
    if ($file.Name -ne "test-launcher.ps1" -and ($text.Contains('"' + $noExitFlag + '"') -or $text.Contains("'" + $noExitFlag + "'"))) { $noExitMatches += $file.Name }
}
if ($noExitMatches.Count -eq 0) {
    $success += "✓ Launcher tests do not use the NoExit flag"
} else {
    $errors += "✗ Launcher tests must not use the NoExit flag: $($noExitMatches -join ', ')"
}

$compileText = Get-FileText ".\compile-v4.2.ps1"
if ($compileText -and $compileText -match 'Copy-Item[\s\S]*iOS-VCAM-Launcher\.exe|compatOutputFile') {
    $errors += "✗ compile-v4.2.ps1 must not recreate the stale root iOS-VCAM-Launcher.exe"
} else {
    $success += "✓ Legacy compile script does not recreate root EXE launcher"
}

$option9Docs = @("docs\Home.md", "docs\Advanced-Features.md", "docs\Troubleshooting.md")
foreach ($doc in $option9Docs) {
    $text = Get-FileText $doc
    if ($text -and (
        $text -match 'SSH Installation Tool.*Option \[9\]' -or
        $text -match 'Automated Installation \(Option \[9\]\)' -or
        $text -match 'Option \[9\].*(directly install|install or update)'
    )) {
        $errors += "✗ $doc still advertises Option [9] as the removed .deb installer"
    }
}
if (-not ($errors | Where-Object { $_ -match 'Option \[9\]' })) {
    $success += "✓ Option [9] docs no longer advertise the removed .deb installer"
}

$unsafeInstallMatches = @()
$scanFiles = @()
$scanFiles += Get-ChildItem ".\docs" -Filter "*.md" -File -ErrorAction SilentlyContinue
$scanFiles += Get-Item ".\iOS-VCAM-Launcher.ps1" -ErrorAction SilentlyContinue
foreach ($file in $scanFiles) {
    $lines = Get-Content -Path $file.FullName -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match 'install(?:ing)?\s+`?com\.iosvcam\.audiobridge(?!\.safe)' -and
            $line -notmatch 'Do not|do not|not safe|should not|must not|quarantine|quarantined|unsafe|不应|不要|不能|已隔离') {
            $unsafeInstallMatches += "$($file.FullName):$($i + 1)"
        }
    }
}
if ($unsafeInstallMatches.Count -eq 0) {
    $success += "✓ Quarantined com.iosvcam.audiobridge is not recommended for install"
} else {
    $errors += "✗ Quarantined com.iosvcam.audiobridge appears as an install recommendation: $($unsafeInstallMatches -join ', ')"
}

$staleSafePackages = @(Get-ChildItem ".\ios\audio_bridge_safe_tweak\packages" -Filter "*.deb" -ErrorAction SilentlyContinue)
if ($staleSafePackages.Count -gt 0) {
    $warnings += "⚠ Development-only safe audio bridge package artifacts present: $($staleSafePackages.Name -join ', ')"
}
Write-Host ""

# Display results
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "                           TEST RESULTS" -ForegroundColor White
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

if ($success.Count -gt 0) {
    Write-Host "SUCCESS ($($success.Count)):" -ForegroundColor Green
    foreach ($item in $success) {
        Write-Host "  $item" -ForegroundColor Green
    }
    Write-Host ""
}

if ($warnings.Count -gt 0) {
    Write-Host "WARNINGS ($($warnings.Count)):" -ForegroundColor Yellow
    foreach ($item in $warnings) {
        Write-Host "  $item" -ForegroundColor Yellow
    }
    Write-Host ""
}

if ($errors.Count -gt 0) {
    Write-Host "ERRORS ($($errors.Count)):" -ForegroundColor Red
    foreach ($item in $errors) {
        Write-Host "  $item" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "RESULT: FAILED - Please fix errors before using the launcher" -ForegroundColor Red
    exit 1
}

Write-Host "============================================================================" -ForegroundColor Green
Write-Host "               ✓ ALL CRITICAL TESTS PASSED!" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "The iOS-VCAM Launcher is ready to use!" -ForegroundColor Cyan
Write-Host ""
Write-Host "To launch:" -ForegroundColor Yellow
Write-Host "  Double-click: iOS-VCAM-Launcher.bat" -ForegroundColor White
Write-Host "  Or run: powershell -ExecutionPolicy Bypass -File .\iOS-VCAM-Launcher.ps1" -ForegroundColor White
Write-Host ""
exit 0

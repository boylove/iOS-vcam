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

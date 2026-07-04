<#
.SYNOPSIS
    Build the iOS-VCAM Audio Bridge tweak .deb through GitHub Actions.

.DESCRIPTION
    Replays the GitHub build flow used during development:
      1. Ensures GitHub CLI is available and authenticated.
      2. Finds or creates a fork of the upstream repository under the logged-in account.
      3. Adds/updates a git remote for that fork.
      4. Optionally commits the workflow/tweak source paths.
      5. Pushes the build branch to the fork.
      6. Runs the GitHub Actions workflow.
      7. Watches the run and downloads the .deb artifact.

    The script does not install anything on the iPhone.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File scripts/github_build_audio_bridge_deb.ps1

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File scripts/github_build_audio_bridge_deb.ps1 -CommitChanges
#>

[CmdletBinding()]
param(
    [string]$UpstreamRepo = "LiuSky/iOS-vcam",
    [string]$ForkRepo = "",
    [string]$Branch = "",
    [string]$RemoteName = "build-fork",
    [string]$Workflow = "build-audio-bridge-tweak.yml",
    [string]$ArtifactName = "iosvcam-audio-bridge-rootless-deb",
    [string]$DownloadDir = "ios/audio_bridge_tweak/packages",
    [string]$GhPath = "",
    [switch]$CommitChanges,
    [switch]$SkipFork,
    [switch]$SkipWorkflowDispatch
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($Arguments -join ' ')"
    }
}

function Get-GitRoot {
    $root = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($root)) {
        throw "Run this script inside a git repository."
    }
    return $root.Trim()
}

function Get-GitHubRepoNameFromRemote {
    $url = (& git remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($url)) {
        return "iOS-vcam"
    }
    $url = $url.Trim()
    if ($url -match 'github\.com[:/][^/]+/([^/.]+)(\.git)?$') {
        return $Matches[1]
    }
    return "iOS-vcam"
}

function Ensure-GitHubCli {
    param([string]$PreferredPath)

    if ($PreferredPath -and (Test-Path $PreferredPath -PathType Leaf)) {
        return (Resolve-Path $PreferredPath).Path
    }

    $cmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $portable = Join-Path $env:TEMP "gh-cli-portable\bin\gh.exe"
    if (Test-Path $portable -PathType Leaf) {
        return $portable
    }

    Write-Step "Downloading portable GitHub CLI"
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/cli/cli/releases/latest" -Headers @{ "User-Agent" = "iOS-VCAM-build-script" }
    $asset = $release.assets | Where-Object { $_.name -match 'windows_amd64\.zip$' } | Select-Object -First 1
    if (-not $asset) {
        throw "Could not find GitHub CLI windows_amd64 zip asset. Install gh manually and rerun."
    }

    $destDir = Join-Path $env:TEMP "gh-cli-portable"
    $zip = Join-Path $env:TEMP $asset.name
    if (Test-Path $destDir) { Remove-Item -Recurse -Force $destDir }
    New-Item -ItemType Directory -Force $destDir | Out-Null
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -Headers @{ "User-Agent" = "iOS-VCAM-build-script" }
    Expand-Archive -LiteralPath $zip -DestinationPath $destDir -Force
    $gh = Get-ChildItem -Path $destDir -Recurse -Filter gh.exe | Select-Object -First 1
    if (-not $gh) { throw "gh.exe not found after extracting GitHub CLI." }
    return $gh.FullName
}

function Invoke-GhJson {
    param(
        [string]$Gh,
        [string[]]$Arguments
    )
    $json = (& $Gh @Arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "gh command failed: gh $($Arguments -join ' ')"
    }
    if ([string]::IsNullOrWhiteSpace(($json | Out-String))) {
        return $null
    }
    return ($json | Out-String | ConvertFrom-Json)
}

$repoRoot = Get-GitRoot
Set-Location $repoRoot

$ghExe = Ensure-GitHubCli -PreferredPath $GhPath
Write-Step "Using GitHub CLI: $ghExe"

try {
    Invoke-Checked -FilePath $ghExe -Arguments @("auth", "status")
} catch {
    Write-Host "GitHub CLI is not logged in." -ForegroundColor Yellow
    Write-Host "Run this, complete browser auth, then rerun the script:" -ForegroundColor Yellow
    Write-Host "  & `"$ghExe`" auth login -h github.com -p https -w" -ForegroundColor White
    throw
}

$login = (& $ghExe api user --jq ".login").Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($login)) {
    throw "Could not determine authenticated GitHub user."
}
Write-Host "GitHub account: $login" -ForegroundColor Green

if ([string]::IsNullOrWhiteSpace($ForkRepo)) {
    $repoName = Get-GitHubRepoNameFromRemote
    $ForkRepo = "$login/$repoName"
}
Write-Host "Fork repo: $ForkRepo" -ForegroundColor Green

if ([string]::IsNullOrWhiteSpace($Branch)) {
    $Branch = (& git branch --show-current).Trim()
    if ([string]::IsNullOrWhiteSpace($Branch)) {
        $Branch = "build/audio-bridge-tweak"
    }
}
Write-Host "Build branch: $Branch" -ForegroundColor Green

if (-not $SkipFork) {
    Write-Step "Ensuring fork exists"
    & $ghExe repo view $ForkRepo *> $null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Checked -FilePath $ghExe -Arguments @("repo", "fork", $UpstreamRepo, "--clone=false")
    } else {
        Write-Host "Fork already exists: https://github.com/$ForkRepo" -ForegroundColor Green
    }
}

Write-Step "Configuring git remote '$RemoteName'"
$remoteUrl = "https://github.com/$ForkRepo.git"
& git remote get-url $RemoteName *> $null
if ($LASTEXITCODE -eq 0) {
    Invoke-Checked -FilePath "git" -Arguments @("remote", "set-url", $RemoteName, $remoteUrl)
} else {
    Invoke-Checked -FilePath "git" -Arguments @("remote", "add", $RemoteName, $remoteUrl)
}
Invoke-Checked -FilePath $ghExe -Arguments @("auth", "setup-git")

if ($CommitChanges) {
    Write-Step "Committing build workflow and tweak source changes"
    Invoke-Checked -FilePath "git" -Arguments @("add", "--", ".github/workflows/build-audio-bridge-tweak.yml", "ios/audio_bridge_tweak")
    & git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Host "No staged changes to commit." -ForegroundColor Gray
    } else {
        $message = @"
Update audio bridge tweak GitHub build

Refresh the GitHub Actions/Theos build inputs for the iOS-VCAM audio bridge companion tweak.

Co-Authored-By: Claude <noreply@anthropic.com>
"@
        Invoke-Checked -FilePath "git" -Arguments @("commit", "-m", $message)
    }
}

Write-Step "Pushing branch to fork"
Invoke-Checked -FilePath "git" -Arguments @("push", "-u", $RemoteName, "HEAD:$Branch")

if (-not $SkipWorkflowDispatch) {
    Write-Step "Triggering workflow_dispatch"
    Invoke-Checked -FilePath $ghExe -Arguments @("workflow", "run", $Workflow, "-R", $ForkRepo, "--ref", $Branch)
    Start-Sleep -Seconds 5
}

Write-Step "Finding latest workflow run"
$run = $null
for ($i = 0; $i -lt 12; $i++) {
    $runs = Invoke-GhJson -Gh $ghExe -Arguments @("run", "list", "-R", $ForkRepo, "--workflow", $Workflow, "--branch", $Branch, "--limit", "1", "--json", "databaseId,status,conclusion,url,createdAt,headSha")
    if ($runs -and $runs.Count -gt 0) {
        $run = @($runs)[0]
        break
    }
    Start-Sleep -Seconds 5
}
if (-not $run) {
    throw "Could not find a workflow run for $Workflow on branch $Branch."
}

$runId = [string]$run.databaseId
Write-Host "Run: $($run.url)" -ForegroundColor Green

Write-Step "Watching workflow run $runId"
& $ghExe run watch $runId -R $ForkRepo --exit-status
if ($LASTEXITCODE -ne 0) {
    Write-Host "Workflow failed. Failed logs:" -ForegroundColor Red
    & $ghExe run view $runId -R $ForkRepo --log-failed
    throw "Workflow run failed: $($run.url)"
}

Write-Step "Downloading .deb artifact"
$downloadPath = if ([System.IO.Path]::IsPathRooted($DownloadDir)) { $DownloadDir } else { Join-Path $repoRoot $DownloadDir }
New-Item -ItemType Directory -Force $downloadPath | Out-Null
Invoke-Checked -FilePath $ghExe -Arguments @("run", "download", $runId, "-R", $ForkRepo, "-n", $ArtifactName, "--dir", $downloadPath)

$debs = @(Get-ChildItem -Path $downloadPath -Recurse -Filter "*.deb" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if ($debs.Count -eq 0) {
    throw "Workflow succeeded but no .deb was downloaded to $downloadPath."
}

Write-Step "Build complete"
foreach ($deb in $debs) {
    Write-Host ("{0} ({1} bytes)" -f $deb.FullName, $deb.Length) -ForegroundColor Green
}
Write-Host "Workflow run: $($run.url)" -ForegroundColor Cyan

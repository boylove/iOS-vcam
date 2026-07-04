#!/usr/bin/env python3
"""Build the restricted iOS-VCAM AudioBridgeSafe .deb via GitHub Actions.

This Windows-friendly wrapper uses the existing GitHub Actions workflow:

    .github/workflows/build-audio-bridge-safe-tweak.yml

Default behavior:
1. Locate or download GitHub CLI.
2. Verify GitHub CLI auth (the current project uses the boylove account/remote).
3. Optionally commit safe AudioBridge build inputs.
4. Push the current branch to the configured remote.
5. Trigger the safe AudioBridge workflow.
6. Watch the run.
7. Download the .deb artifact into ios/audio_bridge_safe_tweak/packages/.

It does not install anything on the iPhone.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path
from typing import Iterable, Optional

DEFAULT_REPO = "boylove/iOS-vcam"
DEFAULT_REMOTE = "boylove"
DEFAULT_BRANCH = "build/audio-bridge-tweak"
DEFAULT_WORKFLOW = "build-audio-bridge-safe-tweak.yml"
DEFAULT_ARTIFACT = "iosvcam-audio-bridge-safe-rootless-deb"
DEFAULT_DOWNLOAD_DIR = Path("ios/audio_bridge_safe_tweak/packages")
COMMIT_PATHS = [
    ".github/workflows/build-audio-bridge-safe-tweak.yml",
    "ios/audio_bridge_safe_tweak/Makefile",
    "ios/audio_bridge_safe_tweak/Tweak.x",
    "ios/audio_bridge_safe_tweak/control",
    "ios/audio_bridge_safe_tweak/README.md",
    "ios/audio_bridge_safe_tweak/iOSVCAMAudioBridgeSafe.plist",
    "ios/audio_bridge_safe_tweak/layout/DEBIAN/postinst",
    "ios/audio_bridge_safe_tweak/layout/DEBIAN/postrm",
    "scripts/github_build_audio_bridge_safe_deb.py",
    ".claude/commands/build-audio-bridge-safe-deb.md",
]


def step(message: str) -> None:
    print(f"\n==> {message}")


def run(
    args: list[str | os.PathLike[str]],
    *,
    cwd: Optional[Path] = None,
    check: bool = True,
    capture: bool = False,
) -> subprocess.CompletedProcess[str]:
    cmd = [str(arg) for arg in args]
    result = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and result.returncode != 0:
        if capture:
            if result.stdout:
                print(result.stdout, end="")
            if result.stderr:
                print(result.stderr, end="", file=sys.stderr)
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(cmd)}")
    return result


def output(args: list[str | os.PathLike[str]], *, cwd: Optional[Path] = None, check: bool = True) -> str:
    return run(args, cwd=cwd, check=check, capture=True).stdout.strip()


def git_root() -> Path:
    root = output(["git", "rev-parse", "--show-toplevel"])
    if not root:
        raise RuntimeError("run this script inside a git repository")
    return Path(root).resolve()


def download_portable_gh() -> Path:
    step("Downloading portable GitHub CLI")
    request = urllib.request.Request(
        "https://api.github.com/repos/cli/cli/releases/latest",
        headers={"User-Agent": "iOS-VCAM-safe-audio-build-script"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        release = json.loads(response.read().decode("utf-8"))

    asset_url = None
    asset_name = None
    for asset in release.get("assets", []):
        name = asset.get("name", "")
        if re.search(r"windows_amd64\.zip$", name):
            asset_url = asset.get("browser_download_url")
            asset_name = name
            break
    if not asset_url or not asset_name:
        raise RuntimeError("could not find GitHub CLI windows_amd64 zip asset")

    temp_dir = Path(tempfile.gettempdir())
    dest_dir = temp_dir / "gh-cli-portable"
    zip_path = temp_dir / asset_name
    if dest_dir.exists():
        shutil.rmtree(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)

    request = urllib.request.Request(asset_url, headers={"User-Agent": "iOS-VCAM-safe-audio-build-script"})
    with urllib.request.urlopen(request, timeout=300) as response, zip_path.open("wb") as fp:
        shutil.copyfileobj(response, fp)

    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(dest_dir)

    matches = list(dest_dir.rglob("gh.exe"))
    if not matches:
        raise RuntimeError("gh.exe not found after extracting GitHub CLI")
    return matches[0]


def find_gh(preferred: str = "") -> Path:
    if preferred:
        candidate = Path(preferred).expanduser().resolve()
        if candidate.is_file():
            return candidate
        raise RuntimeError(f"--gh path does not exist: {candidate}")

    found = shutil.which("gh")
    if found:
        return Path(found).resolve()

    candidates = [
        Path(r"D:\Temp\gh-cli-portable\bin\gh.exe"),
        Path(tempfile.gettempdir()) / "gh-cli-portable" / "bin" / "gh.exe",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()

    return download_portable_gh()


def ensure_gh_auth(gh: Path) -> str:
    result = run([str(gh), "auth", "status"], check=False, capture=True)
    if result.returncode != 0:
        print("GitHub CLI is not logged in. Run this in PowerShell, complete browser auth, then rerun:")
        print(f'  & "{gh}" auth login -h github.com -p https -w')
        raise RuntimeError("GitHub CLI authentication required")
    login = output([str(gh), "api", "user", "--jq", ".login"])
    if not login:
        raise RuntimeError("could not determine authenticated GitHub user")
    return login


def gh_json(gh: Path, args: Iterable[str]) -> object:
    text = output([str(gh), *args])
    return json.loads(text) if text else None


def current_branch(default: str) -> str:
    branch = output(["git", "branch", "--show-current"], check=False)
    return branch or default


def commit_changes(paths: list[str]) -> None:
    step("Committing safe AudioBridge build inputs")
    existing = [path for path in paths if Path(path).exists()]
    if not existing:
        print("No configured commit paths exist; skipping commit.")
        return

    run(["git", "add", "--", *existing])
    diff = run(["git", "diff", "--cached", "--quiet"], check=False)
    if diff.returncode == 0:
        print("No staged changes to commit.")
        return

    message = (
        "Update safe audio bridge GitHub build\n\n"
        "Refresh the restricted AudioBridgeSafe tweak inputs for GitHub Actions/Theos builds.\n\n"
        "Co-Authored-By: Claude <noreply@anthropic.com>"
    )
    run(["git", "commit", "-m", message])


def push_branch(remote: str, branch: str) -> None:
    step(f"Pushing HEAD to {remote}/{branch}")
    run(["git", "push", remote, f"HEAD:{branch}"])


def trigger_workflow(gh: Path, repo: str, workflow: str, branch: str, skip_dispatch: bool) -> None:
    if skip_dispatch:
        return
    step("Triggering workflow_dispatch")
    run([str(gh), "workflow", "run", workflow, "-R", repo, "--ref", branch])
    time.sleep(8)


def latest_run(gh: Path, repo: str, workflow: str, branch: str) -> dict:
    step("Finding latest workflow run")
    for _ in range(12):
        data = gh_json(
            gh,
            [
                "run",
                "list",
                "-R",
                repo,
                "--workflow",
                workflow,
                "--branch",
                branch,
                "--limit",
                "1",
                "--json",
                "databaseId,status,conclusion,url,createdAt,headSha",
            ],
        )
        runs = data if isinstance(data, list) else []
        if runs:
            return runs[0]
        time.sleep(5)
    raise RuntimeError(f"could not find workflow run for {workflow} on {branch}")


def watch_run(gh: Path, repo: str, run_id: str, run_url: str) -> None:
    step(f"Watching workflow run {run_id}")
    result = run([str(gh), "run", "watch", run_id, "-R", repo, "--exit-status"], check=False)
    if result.returncode == 0:
        return
    print("Workflow failed. Failed logs:", file=sys.stderr)
    run([str(gh), "run", "view", run_id, "-R", repo, "--log-failed"], check=False)
    raise RuntimeError(f"workflow run failed: {run_url}")


def download_artifact(gh: Path, repo: str, run_id: str, artifact: str, download_dir: Path) -> list[Path]:
    step("Downloading .deb artifact")
    download_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="iosvcam-safe-deb-") as tmp:
        tmp_dir = Path(tmp)
        run([str(gh), "run", "download", run_id, "-R", repo, "-n", artifact, "--dir", str(tmp_dir)])
        debs = sorted(tmp_dir.rglob("*.deb"), key=lambda path: path.stat().st_mtime, reverse=True)
        if not debs:
            raise RuntimeError(f"workflow succeeded but artifact {artifact!r} did not contain a .deb")
        copied: list[Path] = []
        for deb in debs:
            dest = download_dir / deb.name
            shutil.copy2(deb, dest)
            copied.append(dest)
        return copied


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build iOS-VCAM AudioBridgeSafe .deb via GitHub Actions")
    parser.add_argument("--repo", default=DEFAULT_REPO, help="GitHub repo for Actions, default: boylove/iOS-vcam")
    parser.add_argument("--remote", default=DEFAULT_REMOTE, help="git remote to push, default: boylove")
    parser.add_argument("--branch", default="", help="default: current branch, fallback build/audio-bridge-tweak")
    parser.add_argument("--workflow", default=DEFAULT_WORKFLOW)
    parser.add_argument("--artifact-name", default=DEFAULT_ARTIFACT)
    parser.add_argument("--download-dir", default=str(DEFAULT_DOWNLOAD_DIR))
    parser.add_argument("--gh", default="", help="Path to gh.exe/gh; auto-detected or downloaded if omitted")
    parser.add_argument("--commit-changes", action="store_true", help="Commit safe AudioBridge build inputs before pushing")
    parser.add_argument("--commit-path", action="append", default=[], help="Additional path to include with --commit-changes")
    parser.add_argument("--skip-push", action="store_true")
    parser.add_argument("--skip-workflow-dispatch", action="store_true")
    parser.add_argument("--no-watch", action="store_true", help="Trigger workflow but do not wait/download")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = git_root()
    os.chdir(root)

    gh = find_gh(args.gh)
    step(f"Using GitHub CLI: {gh}")
    login = ensure_gh_auth(gh)
    print(f"GitHub account: {login}")

    branch = args.branch or current_branch(DEFAULT_BRANCH)
    print(f"Repo: {args.repo}")
    print(f"Remote: {args.remote}")
    print(f"Build branch: {branch}")

    run([str(gh), "auth", "setup-git"])

    if args.commit_changes:
        commit_changes([*COMMIT_PATHS, *args.commit_path])

    if not args.skip_push:
        push_branch(args.remote, branch)

    trigger_workflow(gh, args.repo, args.workflow, branch, args.skip_workflow_dispatch)
    run_info = latest_run(gh, args.repo, args.workflow, branch)
    run_id = str(run_info["databaseId"])
    run_url = str(run_info["url"])
    print(f"Run: {run_url}")

    if args.no_watch:
        print("Not watching/downloading because --no-watch was set.")
        return 0

    watch_run(gh, args.repo, run_id, run_url)
    download_dir = Path(args.download_dir)
    if not download_dir.is_absolute():
        download_dir = root / download_dir
    debs = download_artifact(gh, args.repo, run_id, args.artifact_name, download_dir)

    step("Build complete")
    for deb in debs:
        print(f"{deb} ({deb.stat().st_size} bytes)")
    print(f"Workflow run: {run_url}")
    print("Install manually only after explicit approval; this script does not modify the iPhone.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

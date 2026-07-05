#!/usr/bin/env python3
"""Build the iOS-VCAM AudioBridge daemon .deb via GitHub Actions.

This Windows-friendly wrapper uses:

    .github/workflows/build-audio-bridge-daemon.yml

It builds and downloads an artifact only. It does not install anything on the
iPhone or start the daemon.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from github_build_audio_bridge_safe_deb import (
    DEFAULT_BRANCH,
    DEFAULT_REMOTE,
    DEFAULT_REPO,
    ensure_gh_auth,
    find_gh,
    git_root,
    latest_run,
    output,
    run,
    step,
    trigger_workflow,
    watch_run,
    download_artifact,
)

DEFAULT_WORKFLOW = "build-audio-bridge-daemon.yml"
DEFAULT_ARTIFACT = "iosvcam-audio-bridge-daemon-rootless-deb"
DEFAULT_DOWNLOAD_DIR = Path("ios/audio_bridge_daemon/packages")
COMMIT_PATHS = [
    ".github/workflows/build-audio-bridge-daemon.yml",
    "ios/audio_bridge_common/AudioBridgeShared.h",
    "ios/audio_bridge_daemon/Makefile",
    "ios/audio_bridge_daemon/audio_bridge_daemon.c",
    "ios/audio_bridge_daemon/control",
    "ios/audio_bridge_daemon/daemon.entitlements",
    "ios/audio_bridge_daemon/README.md",
    "ios/audio_bridge_daemon/layout/DEBIAN/postinst",
    "ios/audio_bridge_daemon/layout/DEBIAN/postrm",
    "ios/audio_bridge_daemon/layout/Library/LaunchDaemons/com.iosvcam.audiobridge.daemon.plist",
    "ios/retag_deb_architecture.py",
    "ios/validate_deb.py",
    "tests/test-launcher.ps1",
    "scripts/github_build_audio_bridge_daemon_deb.py",
    "docs/Audio-Bridge-DiCoy-Integration.md",
    "docs/Streaming-Guide.md",
]


def current_branch(default: str) -> str:
    branch = output(["git", "branch", "--show-current"], check=False)
    return branch or default


def commit_changes(paths: list[str]) -> None:
    step("Committing AudioBridge daemon build inputs")
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
        "Add audio bridge daemon build\n\n"
        "Add the passive AudioBridge daemon package inputs for the system audio architecture.\n\n"
        "Co-Authored-By: Claude <noreply@anthropic.com>"
    )
    run(["git", "commit", "-m", message])


def push_branch(remote: str, branch: str) -> None:
    step(f"Pushing HEAD to {remote}/{branch}")
    run(["git", "push", remote, f"HEAD:{branch}"])


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build iOS-VCAM AudioBridge daemon .deb via GitHub Actions")
    parser.add_argument("--repo", default=DEFAULT_REPO, help="GitHub repo for Actions, default: boylove/iOS-vcam")
    parser.add_argument("--remote", default=DEFAULT_REMOTE, help="git remote to push, default: boylove")
    parser.add_argument("--branch", default="", help="default: current branch, fallback build/audio-bridge-tweak")
    parser.add_argument("--workflow", default=DEFAULT_WORKFLOW)
    parser.add_argument("--artifact-name", default=DEFAULT_ARTIFACT)
    parser.add_argument("--download-dir", default=str(DEFAULT_DOWNLOAD_DIR))
    parser.add_argument("--gh", default="", help="Path to gh.exe/gh; auto-detected or downloaded if omitted")
    parser.add_argument("--commit-changes", action="store_true", help="Commit daemon build inputs before pushing")
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
    print("Install/start manually only after explicit approval; this script does not modify the iPhone.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

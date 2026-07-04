#!/usr/bin/env python3
"""Build the iOS-VCAM Audio Bridge tweak .deb through GitHub Actions.

This script is the reusable Windows-friendly wrapper for the GitHub build flow:

1. Ensure GitHub CLI is available and authenticated.
2. Create/reuse a fork under the authenticated GitHub account.
3. Add/update a git remote for that fork.
4. Optionally commit build-related paths.
5. Push the current branch to the fork.
6. Trigger and watch the GitHub Actions workflow.
7. Download the built .deb artifact.

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

DEFAULT_UPSTREAM_REPO = "LiuSky/iOS-vcam"
DEFAULT_WORKFLOW = "build-audio-bridge-tweak.yml"
DEFAULT_ARTIFACT = "iosvcam-audio-bridge-rootless-deb"
DEFAULT_DOWNLOAD_DIR = Path("ios/audio_bridge_tweak/packages")
DEFAULT_REMOTE = "build-fork"
COMMIT_PATHS = [
    ".github/workflows/build-audio-bridge-tweak.yml",
    "ios/audio_bridge_tweak",
    "scripts/github_build_audio_bridge_deb.py",
    ".claude/commands/build-audio-bridge-deb.md",
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


def get_git_root() -> Path:
    root = output(["git", "rev-parse", "--show-toplevel"])
    if not root:
        raise RuntimeError("run this script inside a git repository")
    return Path(root).resolve()


def parse_repo_name_from_origin() -> str:
    result = run(["git", "remote", "get-url", "origin"], capture=True, check=False)
    if result.returncode != 0:
        return "iOS-vcam"
    remote_url = result.stdout.strip()
    match = re.search(r"github\.com[:/][^/]+/([^/.]+)(?:\.git)?$", remote_url)
    return match.group(1) if match else "iOS-vcam"


def download_portable_gh() -> Path:
    step("Downloading portable GitHub CLI")
    request = urllib.request.Request(
        "https://api.github.com/repos/cli/cli/releases/latest",
        headers={"User-Agent": "iOS-VCAM-build-script"},
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

    request = urllib.request.Request(asset_url, headers={"User-Agent": "iOS-VCAM-build-script"})
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

    portable = Path(tempfile.gettempdir()) / "gh-cli-portable" / "bin" / "gh.exe"
    if portable.is_file():
        return portable

    return download_portable_gh()


def gh_json(gh: Path, args: Iterable[str]) -> object:
    text = output([str(gh), *args])
    if not text:
        return None
    return json.loads(text)


def ensure_gh_auth(gh: Path) -> None:
    result = run([str(gh), "auth", "status"], check=False)
    if result.returncode == 0:
        return
    print("GitHub CLI is not logged in. Run this in PowerShell, complete browser auth, then rerun:")
    print(f'  & "{gh}" auth login -h github.com -p https -w')
    raise RuntimeError("GitHub CLI authentication required")


def github_login(gh: Path) -> str:
    login = output([str(gh), "api", "user", "--jq", ".login"])
    if not login:
        raise RuntimeError("could not determine authenticated GitHub user")
    return login


def ensure_fork(gh: Path, upstream_repo: str, fork_repo: str, skip_fork: bool) -> None:
    if skip_fork:
        return
    step("Ensuring fork exists")
    exists = run([str(gh), "repo", "view", fork_repo], check=False, capture=True)
    if exists.returncode == 0:
        print(f"Fork already exists: https://github.com/{fork_repo}")
        return
    run([str(gh), "repo", "fork", upstream_repo, "--clone=false"])


def ensure_remote(remote_name: str, fork_repo: str) -> None:
    step(f"Configuring git remote '{remote_name}'")
    remote_url = f"https://github.com/{fork_repo}.git"
    existing = run(["git", "remote", "get-url", remote_name], check=False, capture=True)
    if existing.returncode == 0:
        run(["git", "remote", "set-url", remote_name, remote_url])
    else:
        run(["git", "remote", "add", remote_name, remote_url])


def commit_changes(paths: list[str]) -> None:
    step("Committing build workflow and tweak source changes")
    existing_paths = [path for path in paths if Path(path).exists()]
    if not existing_paths:
        print("No configured commit paths exist; skipping commit.")
        return
    run(["git", "add", "--", *existing_paths])
    diff = run(["git", "diff", "--cached", "--quiet"], check=False)
    if diff.returncode == 0:
        print("No staged changes to commit.")
        return
    message = (
        "Update audio bridge tweak GitHub build\n\n"
        "Refresh the GitHub Actions/Theos build inputs for the iOS-VCAM audio bridge companion tweak.\n\n"
        "Co-Authored-By: Claude <noreply@anthropic.com>"
    )
    run(["git", "commit", "-m", message])


def current_branch(default_branch: str) -> str:
    branch = output(["git", "branch", "--show-current"], check=False)
    return branch or default_branch


def push_branch(remote_name: str, branch: str) -> None:
    step("Pushing branch to fork")
    run(["git", "push", "-u", remote_name, f"HEAD:{branch}"])


def trigger_workflow(gh: Path, fork_repo: str, workflow: str, branch: str, skip_dispatch: bool) -> None:
    if skip_dispatch:
        return
    step("Triggering workflow_dispatch")
    run([str(gh), "workflow", "run", workflow, "-R", fork_repo, "--ref", branch])
    time.sleep(5)


def latest_run(gh: Path, fork_repo: str, workflow: str, branch: str) -> dict:
    step("Finding latest workflow run")
    for _ in range(12):
        data = gh_json(
            gh,
            [
                "run",
                "list",
                "-R",
                fork_repo,
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


def watch_run(gh: Path, fork_repo: str, run_id: str, run_url: str) -> None:
    step(f"Watching workflow run {run_id}")
    result = run([str(gh), "run", "watch", run_id, "-R", fork_repo, "--exit-status"], check=False)
    if result.returncode == 0:
        return
    print("Workflow failed. Failed logs:", file=sys.stderr)
    run([str(gh), "run", "view", run_id, "-R", fork_repo, "--log-failed"], check=False)
    raise RuntimeError(f"workflow run failed: {run_url}")


def download_artifact(gh: Path, fork_repo: str, run_id: str, artifact_name: str, download_dir: Path) -> list[Path]:
    step("Downloading .deb artifact")
    download_dir.mkdir(parents=True, exist_ok=True)
    run([str(gh), "run", "download", run_id, "-R", fork_repo, "-n", artifact_name, "--dir", str(download_dir)])
    debs = sorted(download_dir.rglob("*.deb"), key=lambda path: path.stat().st_mtime, reverse=True)
    if not debs:
        raise RuntimeError(f"workflow succeeded but no .deb was downloaded to {download_dir}")
    return debs


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build iOS-VCAM Audio Bridge .deb via GitHub Actions")
    parser.add_argument("--upstream-repo", default=DEFAULT_UPSTREAM_REPO)
    parser.add_argument("--fork-repo", default="", help="Default: <authenticated-user>/<origin-repo-name>")
    parser.add_argument("--branch", default="", help="Default: current git branch")
    parser.add_argument("--remote-name", default=DEFAULT_REMOTE)
    parser.add_argument("--workflow", default=DEFAULT_WORKFLOW)
    parser.add_argument("--artifact-name", default=DEFAULT_ARTIFACT)
    parser.add_argument("--download-dir", default=str(DEFAULT_DOWNLOAD_DIR))
    parser.add_argument("--gh", default="", help="Path to gh.exe/gh; auto-detected or downloaded if omitted")
    parser.add_argument("--commit-changes", action="store_true")
    parser.add_argument("--skip-fork", action="store_true")
    parser.add_argument("--skip-workflow-dispatch", action="store_true")
    parser.add_argument(
        "--commit-path",
        action="append",
        default=[],
        help="Additional path to include when --commit-changes is used; can be repeated.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = get_git_root()
    os.chdir(repo_root)

    gh = find_gh(args.gh)
    step(f"Using GitHub CLI: {gh}")
    ensure_gh_auth(gh)

    login = github_login(gh)
    print(f"GitHub account: {login}")

    fork_repo = args.fork_repo or f"{login}/{parse_repo_name_from_origin()}"
    branch = args.branch or current_branch("build/audio-bridge-tweak")
    print(f"Fork repo: {fork_repo}")
    print(f"Build branch: {branch}")

    ensure_fork(gh, args.upstream_repo, fork_repo, args.skip_fork)
    ensure_remote(args.remote_name, fork_repo)
    run([str(gh), "auth", "setup-git"])

    if args.commit_changes:
        commit_changes([*COMMIT_PATHS, *args.commit_path])

    push_branch(args.remote_name, branch)
    trigger_workflow(gh, fork_repo, args.workflow, branch, args.skip_workflow_dispatch)
    run_info = latest_run(gh, fork_repo, args.workflow, branch)
    run_id = str(run_info["databaseId"])
    run_url = str(run_info["url"])
    print(f"Run: {run_url}")

    watch_run(gh, fork_repo, run_id, run_url)
    download_dir = Path(args.download_dir)
    if not download_dir.is_absolute():
        download_dir = repo_root / download_dir
    debs = download_artifact(gh, fork_repo, run_id, args.artifact_name, download_dir)

    step("Build complete")
    for deb in debs:
        print(f"{deb} ({deb.stat().st_size} bytes)")
    print(f"Workflow run: {run_url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

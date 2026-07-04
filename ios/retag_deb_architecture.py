#!/usr/bin/env python3
"""Retag Debian control Architecture fields inside .deb archives.

Theos rootless builds can emit `iphoneos-arm64` package metadata even when the
package is intended for an arm64e device dpkg database. This helper rewrites the
control tarball in-place and, by default, renames the file so the filename and
control metadata match.
"""

from __future__ import annotations

import argparse
import io
import tarfile
from pathlib import Path

AR_MAGIC = b"!<arch>\n"


def read_ar(path: Path) -> list[tuple[str, bytes]]:
    data = path.read_bytes()
    if not data.startswith(AR_MAGIC):
        raise ValueError(f"{path} is not a Debian ar archive")
    pos = len(AR_MAGIC)
    members: list[tuple[str, bytes]] = []
    while pos < len(data):
        header = data[pos : pos + 60]
        if not header:
            break
        if len(header) != 60:
            raise ValueError(f"{path} has a truncated ar header")
        name = header[:16].decode("ascii").strip().rstrip("/")
        size = int(header[48:58].decode("ascii").strip() or "0")
        pos += 60
        content = data[pos : pos + size]
        pos += size
        if size % 2:
            pos += 1
        members.append((name, content))
    return members


def write_ar(path: Path, members: list[tuple[str, bytes]]) -> None:
    with path.open("wb") as ar:
        ar.write(AR_MAGIC)
        for name, content in members:
            if len(name) > 16:
                raise ValueError(f"ar member name too long: {name}")
            header = (
                name.ljust(16)
                + "0".ljust(12)
                + "0".ljust(6)
                + "0".ljust(6)
                + "100644".ljust(8)
                + str(len(content)).ljust(10)
                + "`\n"
            ).encode("ascii")
            ar.write(header)
            ar.write(content)
            if len(content) % 2:
                ar.write(b"\n")


def normalize_tar_name(name: str) -> str:
    return name[2:] if name.startswith("./") else name


def retag_control(control_tgz: bytes, architecture: str) -> tuple[bytes, str]:
    out = io.BytesIO()
    old_arch = ""
    changed = False
    with tarfile.open(fileobj=io.BytesIO(control_tgz), mode="r:gz") as src_tar:
        with tarfile.open(fileobj=out, mode="w:gz", format=tarfile.GNU_FORMAT) as dst_tar:
            for member in src_tar.getmembers():
                extracted = src_tar.extractfile(member) if member.isfile() else None
                content = extracted.read() if extracted else b""
                if normalize_tar_name(member.name) == "control":
                    text = content.decode("utf-8")
                    lines = []
                    for line in text.splitlines(keepends=True):
                        if line.startswith("Architecture:"):
                            old_arch = line.split(":", 1)[1].strip()
                            newline = "\n" if line.endswith("\n") else ""
                            line = f"Architecture: {architecture}{newline}"
                            changed = True
                        lines.append(line)
                    content = "".join(lines).encode("utf-8")
                    member.size = len(content)
                member.pax_headers = {}
                dst_tar.addfile(member, io.BytesIO(content) if member.isfile() else None)
    if not changed:
        raise ValueError("control file or Architecture field not found")
    return out.getvalue(), old_arch


def output_path_for(path: Path, old_arch: str, new_arch: str) -> Path:
    if old_arch and old_arch in path.name:
        return path.with_name(path.name.replace(old_arch, new_arch))
    stem = path.name.removesuffix(".deb")
    return path.with_name(f"{stem}_{new_arch}.deb")


def retag_deb(path: Path, architecture: str, keep_original: bool) -> Path:
    members: list[tuple[str, bytes]] = []
    old_arch = ""
    for name, content in read_ar(path):
        if name == "control.tar.gz":
            content, old_arch = retag_control(content, architecture)
        members.append((name, content))
    dest = path if keep_original else output_path_for(path, old_arch, architecture)
    write_ar(dest, members)
    if not keep_original and dest != path:
        path.unlink()
    print(f"{path} -> {dest} ({old_arch or 'unknown'} -> {architecture})")
    return dest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("deb", nargs="+", type=Path)
    parser.add_argument("--architecture", default="iphoneos-arm64e")
    parser.add_argument("--keep-original", action="store_true")
    args = parser.parse_args()

    for deb in args.deb:
        retag_deb(deb, args.architecture, args.keep_original)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

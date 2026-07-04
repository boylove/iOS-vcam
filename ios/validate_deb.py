#!/usr/bin/env python3
import argparse
import io
import lzma
import re
import sys
import tarfile

AR_MAGIC = b"!<arch>\n"
SAFE_PACKAGE = "com.iosvcam.audiobridge.safe"
ROOTLESS_TWEAK_DIR = "var/jb/Library/MobileSubstrate/DynamicLibraries"
SAFE_DYLIB = f"{ROOTLESS_TWEAK_DIR}/iOSVCAMAudioBridgeSafe.dylib"
SAFE_PLIST = f"{ROOTLESS_TWEAK_DIR}/iOSVCAMAudioBridgeSafe.plist"
SAFE_BACKUP_DYLIB = "var/jb/usr/lib/iosvcam/iOSVCAMAudioBridgeSafe.dylib"
MEDIA_PROBE_PACKAGE = "com.iosvcam.audiobridge.media-probe"
MEDIA_PROBE_DYLIB = f"{ROOTLESS_TWEAK_DIR}/iOSVCAMAudioBridgeMediaProbe.dylib"
MEDIA_PROBE_PLIST = f"{ROOTLESS_TWEAK_DIR}/iOSVCAMAudioBridgeMediaProbe.plist"
MEDIA_PROBE_BACKUP_DYLIB = "var/jb/usr/lib/iosvcam/iOSVCAMAudioBridgeMediaProbe.dylib"
MEDIA_ACTIVE_PACKAGE = "com.iosvcam.audiobridge.media-active"
MEDIA_ACTIVE_DYLIB = f"{ROOTLESS_TWEAK_DIR}/iOSVCAMAudioBridgeMediaActive.dylib"
MEDIA_ACTIVE_PLIST = f"{ROOTLESS_TWEAK_DIR}/iOSVCAMAudioBridgeMediaActive.plist"
MEDIA_ACTIVE_BACKUP_DYLIB = "var/jb/usr/lib/iosvcam/iOSVCAMAudioBridgeMediaActive.dylib"
VCAM_DYLIB = f"{ROOTLESS_TWEAK_DIR}/vcamera.dylib"
VCAM_PLIST = f"{ROOTLESS_TWEAK_DIR}/vcamera.plist"
VCAM_PREF_PAYLOAD_PATH = "var/mobile/vc.plist"


def read_members(f):
    if f.read(8) != AR_MAGIC:
        raise ValueError("Missing ar global header")
    members = []
    while True:
        hdr = f.read(60)
        if not hdr:
            break
        if len(hdr) < 60:
            raise ValueError("Truncated member header")
        name = hdr[0:16].decode("ascii").strip()
        size = int(hdr[48:58].decode("ascii").strip() or "0")
        data = f.read(size)
        if size % 2 == 1:
            f.read(1)
        members.append((name, data))
    return members


def normalize_tar_name(name):
    return name[2:] if name.startswith("./") else name


def read_tar_entries(data, mode):
    entries = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode=mode) as tar:
        for member in tar.getmembers():
            name = normalize_tar_name(member.name)
            content = b""
            if member.isfile():
                extracted = tar.extractfile(member)
                if extracted:
                    content = extracted.read()
            entries[name] = content
    return entries


def parse_control_fields(control_bytes):
    text = control_bytes.decode("utf-8", errors="replace")
    fields = {}
    current = None
    for line in text.splitlines():
        if not line:
            continue
        if line[0].isspace() and current:
            fields[current] += "\n" + line.strip()
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        current = key.strip()
        fields[current] = value.strip()
    return fields, text


def decode_data_tar(data_name, data_bytes):
    sig = data_bytes[:6]
    if sig.startswith(b"\x5d\x00\x00"):
        print("OK: LZMA-alone")
        tar_bytes = lzma.decompress(data_bytes, format=lzma.FORMAT_ALONE)
        return read_tar_entries(tar_bytes, "r:")
    if sig.startswith(b"\xFD7zXZ") or sig[:2] == b"\xFD7":
        raise ValueError("XZ container used")
    print("WARN: Unknown data signature:", sig)
    if data_name.endswith(".gz"):
        return read_tar_entries(data_bytes, "r:gz")
    return {}


def require(condition, message):
    if not condition:
        print(f"FAIL: {message}")
        return False
    return True


def validate_safe_package(control_fields, control_entries, data_entries):
    ok = True
    package = control_fields.get("Package", "")
    if package != SAFE_PACKAGE:
        return True

    ok &= require(
        control_fields.get("Architecture") == "iphoneos-arm64e",
        "safe package Architecture must be iphoneos-arm64e",
    )
    ok &= require(SAFE_DYLIB in data_entries, f"missing {SAFE_DYLIB}")
    ok &= require(SAFE_PLIST in data_entries, f"missing {SAFE_PLIST}")
    ok &= require(SAFE_BACKUP_DYLIB in data_entries, f"missing {SAFE_BACKUP_DYLIB}")

    postinst = control_entries.get("postinst", b"").decode("utf-8", errors="replace")
    postrm = control_entries.get("postrm", b"").decode("utf-8", errors="replace")
    plist = data_entries.get(SAFE_PLIST, b"").decode("utf-8", errors="replace")

    ok &= require("/usr/lib/TweakInject" in postinst, "postinst missing TweakInject handling")
    ok &= require(
        "/usr/lib/DynamicPatches/AutoPatches.dylib" in postinst,
        "postinst missing RootHide AutoPatches link target",
    )
    ok &= require(ROOTLESS_TWEAK_DIR in postinst, "postinst missing rootless source path")
    ok &= require("BACKUP_DYLIB" in postinst, "postinst missing backup dylib restore path")
    ok &= require("PKGMIRROR_DIR" in postinst, "postinst missing RootHide pkgmirror support")
    ok &= require("cp -f" in postinst, "postinst must mirror rootless/backup dylib for RootHide")
    ok &= require("<!DOCTYPE plist" in postinst, "postinst must write an XML RootHide filter plist")
    ok &= require("write_filter_openstep" in postinst, "postinst must write pkgmirror OpenStep filter plist")
    ok &= require("<string>TikTok</string>" in postinst, "postinst XML filter missing TikTok executable")
    ok &= require('case "$1"' in postrm, "postrm must guard cleanup by maintainer-script action")
    ok &= require("remove|purge" in postrm, "postrm cleanup must be limited to remove/purge")
    ok &= require("iOSVCAMAudioBridgeSafe.dylib" in postrm, "postrm missing dylib cleanup")
    ok &= require("iOSVCAMAudioBridgeSafe.plist" in postrm, "postrm missing plist cleanup")
    ok &= require("roothidepatch" in postrm, "postrm missing roothidepatch cleanup")
    ok &= require("PKGMIRROR_DIR" in postrm, "postrm missing pkgmirror cleanup")

    forbidden = [
        r"\bmediaserverd\b",
        r"com\.apple\.mediaserverd",
        r"com\.apple\.camera",
        r"com\.apple\.springboard",
        r"Package:\s*com\.iosvcam\.audiobridge\s*(?:$|\n)",
    ]
    scanned_text = "\n".join([postinst, postrm, plist])
    for pattern in forbidden:
        ok &= require(not re.search(pattern, scanned_text, re.I), f"forbidden safe package content: {pattern}")

    print("OK: Safe AudioBridge package invariants")
    return ok


def validate_media_probe_package(control_fields, control_entries, data_entries):
    ok = True
    package = control_fields.get("Package", "")
    if package != MEDIA_PROBE_PACKAGE:
        return True

    ok &= require(
        control_fields.get("Architecture") == "iphoneos-arm64e",
        "media probe Architecture must be iphoneos-arm64e",
    )
    ok &= require(MEDIA_PROBE_DYLIB in data_entries, f"missing {MEDIA_PROBE_DYLIB}")
    ok &= require(MEDIA_PROBE_PLIST in data_entries, f"missing {MEDIA_PROBE_PLIST}")
    ok &= require(MEDIA_PROBE_BACKUP_DYLIB in data_entries, f"missing {MEDIA_PROBE_BACKUP_DYLIB}")

    postinst = control_entries.get("postinst", b"").decode("utf-8", errors="replace")
    postrm = control_entries.get("postrm", b"").decode("utf-8", errors="replace")
    plist = data_entries.get(MEDIA_PROBE_PLIST, b"").decode("utf-8", errors="replace")
    dylib = data_entries.get(MEDIA_PROBE_DYLIB, b"")

    ok &= require("/usr/lib/TweakInject" in postinst, "media probe postinst missing TweakInject handling")
    ok &= require(
        "/usr/lib/DynamicPatches/AutoPatches.dylib" in postinst,
        "media probe postinst missing RootHide AutoPatches link target",
    )
    ok &= require(ROOTLESS_TWEAK_DIR in postinst, "media probe postinst missing rootless source path")
    ok &= require("BACKUP_DYLIB" in postinst, "media probe postinst missing backup dylib restore path")
    ok &= require("PKGMIRROR_DIR" in postinst, "media probe postinst missing RootHide pkgmirror support")
    ok &= require("com.apple.mediaserverd" in postinst, "media probe postinst missing mediaserverd filter")
    ok &= require("mediaserverd" in plist, "media probe plist missing mediaserverd filter")
    ok &= require('case "$1"' in postrm, "media probe postrm must guard cleanup by maintainer-script action")
    ok &= require("remove|purge" in postrm, "media probe cleanup must be limited to remove/purge")
    ok &= require("iOSVCAMAudioBridgeMediaProbe.dylib" in postrm, "media probe postrm missing dylib cleanup")
    ok &= require("iOSVCAMAudioBridgeMediaProbe.plist" in postrm, "media probe postrm missing plist cleanup")
    ok &= require("roothidepatch" in postrm, "media probe postrm missing roothidepatch cleanup")
    ok &= require(b"MEDIA_PROBE_LOADED" in dylib, "media probe dylib missing load marker")
    ok &= require(b"MEDIA_PROBE_PASSIVE" in dylib, "media probe dylib missing passive marker")

    forbidden_text = "\n".join([postinst, postrm, plist, control_fields.get("Package", "")])
    ok &= require("Package: com.iosvcam.audiobridge\n" not in forbidden_text, "media probe must not use quarantined package id")
    for marker in [b"IAF1", b"AudioUnitRender", b"AVCaptureAudioDataOutput", b"connected to %@:%d"]:
        ok &= require(marker not in dylib, f"media probe must remain passive; found {marker!r}")

    print("OK: Media probe package invariants")
    return ok


def validate_media_active_package(control_fields, control_entries, data_entries):
    ok = True
    package = control_fields.get("Package", "")
    if package != MEDIA_ACTIVE_PACKAGE:
        return True

    ok &= require(
        control_fields.get("Architecture") == "iphoneos-arm64e",
        "media-active Architecture must be iphoneos-arm64e",
    )
    ok &= require(MEDIA_ACTIVE_DYLIB in data_entries, f"missing {MEDIA_ACTIVE_DYLIB}")
    ok &= require(MEDIA_ACTIVE_PLIST in data_entries, f"missing {MEDIA_ACTIVE_PLIST}")
    ok &= require(MEDIA_ACTIVE_BACKUP_DYLIB in data_entries, f"missing {MEDIA_ACTIVE_BACKUP_DYLIB}")

    postinst = control_entries.get("postinst", b"").decode("utf-8", errors="replace")
    postrm = control_entries.get("postrm", b"").decode("utf-8", errors="replace")
    plist = data_entries.get(MEDIA_ACTIVE_PLIST, b"").decode("utf-8", errors="replace")
    dylib = data_entries.get(MEDIA_ACTIVE_DYLIB, b"")

    ok &= require("/usr/lib/TweakInject" in postinst, "media-active postinst missing TweakInject handling")
    ok &= require(
        "/usr/lib/DynamicPatches/AutoPatches.dylib" in postinst,
        "media-active postinst missing RootHide AutoPatches link target",
    )
    ok &= require(ROOTLESS_TWEAK_DIR in postinst, "media-active postinst missing rootless source path")
    ok &= require("BACKUP_DYLIB" in postinst, "media-active postinst missing backup dylib restore path")
    ok &= require("PKGMIRROR_DIR" in postinst, "media-active postinst missing RootHide pkgmirror support")
    ok &= require("com.apple.mediaserverd" in postinst, "media-active postinst missing mediaserverd filter")
    ok &= require("mediaserverd" in plist, "media-active plist missing mediaserverd filter")
    ok &= require("com.zhiliaoapp.musically" not in plist, "media-active plist must not target TikTok")
    ok &= require('case "$1"' in postrm, "media-active postrm must guard cleanup by maintainer-script action")
    ok &= require("remove|purge" in postrm, "media-active cleanup must be limited to remove/purge")
    ok &= require("iOSVCAMAudioBridgeMediaActive.dylib" in postrm, "media-active postrm missing dylib cleanup")
    ok &= require("iOSVCAMAudioBridgeMediaActive.plist" in postrm, "media-active postrm missing plist cleanup")
    ok &= require("roothidepatch" in postrm, "media-active postrm missing roothidepatch cleanup")
    ok &= require(b"MEDIA_ACTIVE_LOADED" in dylib, "media-active dylib missing load marker")
    ok &= require(b"MEDIA_ACTIVE_READY" in dylib, "media-active dylib missing ready marker")
    ok &= require(b"media-active.disabled" in dylib, "media-active dylib missing disable flag")
    ok &= require(b"IAF1" in dylib, "media-active dylib missing AudioBridge protocol marker")
    ok &= require(b"AudioUnitRender" in dylib, "media-active dylib missing AudioUnitRender marker")
    ok &= require(b"127.10.10.10" in dylib, "media-active dylib missing default tunnel host")

    forbidden_text = "\n".join([postinst, postrm, plist, control_fields.get("Package", "")])
    ok &= require("Package: com.iosvcam.audiobridge\n" not in forbidden_text, "media-active must not use quarantined package id")
    for pattern in [r"com\.apple\.camera", r"com\.apple\.springboard", r"com\.zhiliaoapp\.musically", r"\bTikTok\b"]:
        ok &= require(not re.search(pattern, forbidden_text, re.I), f"forbidden media-active target content: {pattern}")

    print("OK: Media-active package invariants")
    return ok


def validate_vcamera_rtmp_seed(expected_rtmp, control_entries, data_entries):
    ok = True
    postinst = control_entries.get("postinst", b"").decode("utf-8", errors="replace")

    ok &= require(VCAM_DYLIB in data_entries, f"missing {VCAM_DYLIB}")
    ok &= require(VCAM_PLIST in data_entries, f"missing {VCAM_PLIST}")
    ok &= require(
        VCAM_PREF_PAYLOAD_PATH not in data_entries,
        "seeded package must not ship var/mobile/vc.plist in data payload",
    )
    ok &= require("/var/mobile/vc.plist" in postinst, "postinst missing vc.plist target")
    ok &= require(expected_rtmp in postinst, "postinst missing expected RTMP URL")
    ok &= require("# iOS-VCAM default RTMP seed begin" in postinst, "postinst missing RTMP seed marker")
    ok &= require("rtmp://*)" in postinst, "postinst must preserve existing rtmp:// values")
    ok &= require("VCAM_DEFAULT_RTMP" in postinst, "postinst missing default RTMP variable")
    ok &= require("iosvcam.bak" in postinst, "postinst missing backup path for existing plist")

    forbidden = [
        r"killall\s+.*SpringBoard",
        r"\bsbreload\b",
        r"\brespring\b",
        r"launchctl\s+.*SpringBoard",
        r"/etc/ssh/sshd_config",
        r"ifconfig\s+lo0\s+alias",
    ]
    for pattern in forbidden:
        ok &= require(not re.search(pattern, postinst, re.I), f"forbidden seeded package postinst content: {pattern}")

    if ok:
        print("OK: VCAM default RTMP seed invariants")
    return ok


def validate(path, expected_vcamera_rtmp=None):
    print(f"Validating: {path}")
    with open(path, "rb") as f:
        members = read_members(f)
    order = [n for n, _ in members]
    print("Order:", order)
    if not require(order[:1] == ["debian-binary"], "debian-binary not first"):
        return 1
    if not require("control.tar.gz" in order, "missing control.tar.gz"):
        return 1
    data_name = next((n for n, _ in members if n.startswith("data.tar")), None)
    if not require(bool(data_name), "missing data.tar.*"):
        return 1
    debbin = next(d for n, d in members if n == "debian-binary")
    if not require(debbin == b"2.0\n", "wrong debian-binary contents"):
        return 1

    ctrl = next(d for n, d in members if n == "control.tar.gz")
    try:
        control_entries = read_tar_entries(ctrl, "r:gz")
    except Exception as e:
        print("FAIL: cannot read control.tar.gz:", e)
        return 1
    if not require("control" in control_entries, "control file missing inside control.tar.gz"):
        return 1

    control_fields, _control_text = parse_control_fields(control_entries["control"])

    data_bytes = next(d for n, d in members if n == data_name)
    try:
        data_entries = decode_data_tar(data_name, data_bytes)
    except Exception as e:
        print("FAIL: cannot read data tar:", e)
        return 1

    if not validate_safe_package(control_fields, control_entries, data_entries):
        return 1
    if not validate_media_probe_package(control_fields, control_entries, data_entries):
        return 1
    if not validate_media_active_package(control_fields, control_entries, data_entries):
        return 1
    if expected_vcamera_rtmp and not validate_vcamera_rtmp_seed(expected_vcamera_rtmp, control_entries, data_entries):
        return 1

    print("PASS")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description="Validate iOS .deb package structure")
    parser.add_argument("paths", nargs="+", help=".deb file(s) to validate")
    parser.add_argument(
        "--expect-vcamera-rtmp",
        help="Assert a vcamera package seeds this RTMP URL in postinst",
    )
    args = parser.parse_args(argv[1:])

    status = 0
    for path in args.paths:
        status = max(status, validate(path, expected_vcamera_rtmp=args.expect_vcamera_rtmp))
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
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

    ok &= require(SAFE_DYLIB in data_entries, f"missing {SAFE_DYLIB}")
    ok &= require(SAFE_PLIST in data_entries, f"missing {SAFE_PLIST}")

    postinst = control_entries.get("postinst", b"").decode("utf-8", errors="replace")
    postrm = control_entries.get("postrm", b"").decode("utf-8", errors="replace")
    plist = data_entries.get(SAFE_PLIST, b"").decode("utf-8", errors="replace")

    ok &= require("/usr/lib/TweakInject" in postinst, "postinst missing TweakInject handling")
    ok &= require(
        "/usr/lib/DynamicPatches/AutoPatches.dylib" in postinst,
        "postinst missing RootHide AutoPatches link target",
    )
    ok &= require(ROOTLESS_TWEAK_DIR in postinst, "postinst missing rootless source path")
    ok &= require("cp -f" in postinst, "postinst must mirror rootless files for RootHide")
    ok &= require("iOSVCAMAudioBridgeSafe.dylib" in postrm, "postrm missing dylib cleanup")
    ok &= require("iOSVCAMAudioBridgeSafe.plist" in postrm, "postrm missing plist cleanup")
    ok &= require("roothidepatch" in postrm, "postrm missing roothidepatch cleanup")

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


def validate(path):
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

    print("PASS")
    return 0


def main(argv):
    if len(argv) < 2:
        print("Usage: python validate_deb.py path/to/file.deb [more.deb ...]")
        return 2
    status = 0
    for path in argv[1:]:
        status = max(status, validate(path))
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))

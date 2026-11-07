#!/usr/bin/env python3
"""Fail the CI publication if the actual DEB is stale or fails ABI checks."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import subprocess
import tarfile
import tempfile

from check_pac import inspect, slices

ROOT = Path(__file__).resolve().parents[1]


def _control_version(name):
    for line in (ROOT / name).read_text(encoding="utf-8").splitlines():
        if line.startswith("Version:"):
            return line.split(":", 1)[1].strip()
    raise SystemExit("no Version field in %s" % name)


# The version lives in control only; deriving it here means a version bump can
# never leave this check hunting for the previous build's file name.
VERSION = _control_version("control")
if _control_version("control.in") != VERSION:
    raise SystemExit("control and control.in disagree on the version")


def signed_pages(path):
    results = []
    for _, image in slices(path.read_bytes()):
        ncmds = struct.unpack_from("<I", image, 16)[0]
        pos = 32
        signature = None
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", image, pos)
            if cmd == 0x1D:
                sigoff, sigsize = struct.unpack_from("<II", image, pos + 8)
                signature = image[sigoff:sigoff + sigsize]
            pos += size
        if signature is None:
            raise ValueError(f"unsigned {path}")
        magic, length, count = struct.unpack_from(">III", signature)
        if magic != 0xFADE0CC0 or length > len(signature):
            raise ValueError("invalid signature superblob")
        code_dirs = 0
        for index in range(count):
            slot, off = struct.unpack_from(">II", signature, 12 + index * 8)
            magic, cdlength = struct.unpack_from(">II", signature, off)
            if magic != 0xFADE0C02:
                continue
            code_dirs += 1
            cd = signature[off:off + cdlength]
            version, _, hash_offset, _, _, ncode, limit = struct.unpack_from(">7I", cd, 8)
            hash_size, hash_type, _, shift = struct.unpack_from("4B", cd, 36)
            if version >= 0x20300 and limit == 0xFFFFFFFF:
                limit = struct.unpack_from(">Q", cd, 56)[0]
            if limit != sigoff or not ncode or shift > 20:
                raise ValueError("invalid CodeDirectory limit/pages")
            page_size = 1 << shift
            if ncode != (limit + page_size - 1) // page_size:
                raise ValueError("CodeDirectory page count mismatch")
            if hash_type not in (1, 2, 3):
                raise ValueError(f"unsupported hash type {hash_type}")
            for page in range(ncode):
                data = image[page * page_size:min((page + 1) * page_size, limit)]
                digest = hashlib.sha1(data).digest() if hash_type == 1 else hashlib.sha256(data).digest()
                stored = cd[hash_offset + page * hash_size:hash_offset + (page + 1) * hash_size]
                if digest[:hash_size] != stored:
                    raise ValueError(f"invalid signature page {page} of {path}")
            results.append({"slot": slot, "hash_type": hash_type, "pages": ncode, "bad": 0})
        if not code_dirs:
            raise ValueError("missing CodeDirectory")
    return results


def field(package, name):
    return subprocess.check_output(["dpkg-deb", "-f", str(package), name], text=True).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scheme", required=True, choices=("roothide", "rootless"))
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    arch = "arm64e" if args.scheme == "roothide" else "arm64"
    debarch = "iphoneos-" + arch
    package = ROOT / "packages" / f"com.moxuan.parallelx_{VERSION}_{debarch}.deb"
    if not package.is_file():
        raise ValueError("expected current package missing")
    for name, expected in (("Package", "com.moxuan.parallelx"), ("Version", VERSION),
                           ("Architecture", debarch), ("Depends", "mobilesubstrate, preferenceloader")):
        if field(package, name) != expected:
            raise ValueError(f"wrong {name}: {field(package, name)}")
    report = {"version": VERSION, "scheme": args.scheme, "architecture": arch, "images": {}}
    with tempfile.TemporaryDirectory() as temp:
        directory = Path(temp)
        payload, controls = directory / "payload", directory / "controls"
        subprocess.run(["dpkg-deb", "-x", str(package), str(payload)], check=True)
        subprocess.run(["dpkg-deb", "-e", str(package), str(controls)], check=True)
        prefix = payload if args.scheme == "roothide" else payload / "var/jb"
        lib = prefix / "Library/MobileSubstrate/DynamicLibraries"
        root = prefix / "Library/PreferenceBundles/ParallelXPrefs.bundle/Root.plist"
        entry = [x for x in plistlib.loads(root.read_bytes())["items"]
                 if x.get("detail") == "PXCloneAccountsController"]
        if len(entry) != 1 or not entry[0].get("isController") or "bundle" in entry[0]:
            raise ValueError("account entry not wired to injected controller")
        if (prefix / "Library/PreferenceBundles/ParallelXClonePrefs.bundle").exists():
            raise ValueError("obsolete standalone prefs bundle still packaged")
        for name, bundle in (("ParallelXClone", None),
                             ("ParallelXPrefsUI", "com.apple.Preferences")):
            image = lib / (name + ".dylib")
            document = plistlib.loads((lib / (name + ".plist")).read_bytes())
            filters = document.get("Filter", {})
            # PXClone must see URL opens from ANY app: match on a class every
            # UIKit process has instead of a bundle whitelist.
            if bundle:
                ok = filters.get("Bundles") == [bundle]
            else:
                ok = ("com.apple.springboard" in (filters.get("Bundles") or [])
                      and "WebContent" in (filters.get("Executables") or []))
            if not ok or image.stat().st_mode & 0o111 == 0:
                raise ValueError(f"wrong filter/permissions for {name}: {filters}")
            pac = inspect(image, arch)
            if any(x["issues"] for x in pac):
                raise ValueError(f"return-address ABI violation: {pac}")
            report["images"][name] = {"pac": pac, "signatures": signed_pages(image)}
            if any(word in subprocess.check_output(["xcrun", "nm", str(image)], text=True)
                   for word in ("__ZL15PXPerformAction", "_PXCloneHookMessage")):
                raise ValueError("unstripped private C hook symbols")
        for original in sorted((ROOT / "vendor/alpha391").rglob("*")):
            if not original.is_file():
                continue
            relative = original.relative_to(ROOT / "vendor/alpha391")
            if str(relative).endswith("ParallelXPrefs.bundle/Root.plist"):
                continue
            installed = prefix / relative
            if installed.read_bytes() != original.read_bytes():
                raise ValueError(f"changed vendor payload: {relative}")
        postinst = controls / "postinst"
        script = postinst.read_text()
        expected_prefix = "" if arch == "arm64e" else "/var/jb"
        if f'PREFIX="{expected_prefix}"' not in script or postinst.stat().st_mode & 0o111 == 0:
            raise ValueError("wrong maintainer path or permissions")
        if "killall" in script or "sbreload" in script or "launchctl" in script:
            raise ValueError("package must not automatically restart SpringBoard")
    args.out.mkdir(parents=True, exist_ok=True)
    destination = args.out / package.name
    shutil.copy2(package, destination)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    (args.out / "SHA256SUMS").write_text(f"{digest}  {destination.name}\n")
    report["package_sha256"] = digest
    (args.out / "VERIFICATION.json").write_text(json.dumps(report, indent=2))
    print(json.dumps({"package": destination.name, "sha256": digest, "verified": True}))


if __name__ == "__main__":
    main()

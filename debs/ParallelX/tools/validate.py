#!/usr/bin/env python3
"""Whole-project local gate. Read-only except temporary scheme checks."""
import hashlib
import os
import plistlib
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEB = "/tmp/pxi/debs/com.moxuan.parallelx_0.1.0~alpha391_iphoneos-arm64e.deb"
EXPECTED_DEB = "76052a287abb9b925c52701bde835152aeab20331e4e90fc39a8f92102d40c50"
VENDOR = os.path.join(ROOT, "vendor/alpha391")


def sha(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fail(message):
    print("FAIL", message)
    return 1


def main():
    errors = 0
    if os.path.exists(DEB):
        if sha(DEB) != EXPECTED_DEB:
            errors += fail("baseline deb hash changed")
        else:
            print("ok baseline deb", EXPECTED_DEB)
    else:
        print("skip baseline deb hash: temporary source package unavailable")

    vendor_files = []
    for base, _, names in os.walk(VENDOR):
        for name in names:
            vendor_files.append(os.path.relpath(os.path.join(base, name), VENDOR))
    vendor_files.sort()
    if len(vendor_files) != 16:
        errors += fail(f"vendor file count {len(vendor_files)} != 16")
    if os.path.exists(DEB):
        with tempfile.TemporaryDirectory() as temp:
            subprocess.run(["dpkg-deb", "-x", DEB, temp], check=True)
            for rel in vendor_files:
                source = os.path.join(temp, rel)
                if not os.path.exists(source):
                    errors += fail(f"vendor extra file {rel}")
                elif sha(source) != sha(os.path.join(VENDOR, rel)):
                    errors += fail(f"vendor changed {rel}")
        print("ok vendor payload", len(vendor_files), "files byte-identical")
    else:
        print("skip vendor DEB comparison: temporary source package unavailable")

    for rel in ["layout/DEBIAN/postinst.in", "Prefs/Resources/Info.plist", "Prefs/Resources/Root.plist",
                "layout/Library/PreferenceBundles/ParallelXPrefs.bundle/Root.plist",
                "ParallelXClone.plist"]:
        data_bytes = open(os.path.join(ROOT, rel), "rb").read()
        if rel.endswith(".plist"):
            try:
                plistlib.loads(data_bytes)
            except Exception:
                # Theos accepts OpenStep plists; pin their structure instead.
                try:
                    data = data_bytes.decode("utf-8")
                except UnicodeDecodeError:
                    errors += fail(f"bad plist encoding {rel}")
                    continue
                if data.count("{") != data.count("}") or data.count("(") != data.count(")"):
                    errors += fail(f"bad plist structure {rel}")
    print("ok plists")

    for scheme, prefix in (("roothide", ""), ("rootless", "/var/jb")):
        subprocess.run(["./tools/generate_maintainer_scripts.sh", scheme], cwd=ROOT, check=True)
        script = open(os.path.join(ROOT, "layout/DEBIAN/postinst")).read()
        if f'PREFIX="{prefix}"' not in script:
            errors += fail(f"postinst prefix wrong for {scheme}")
        if not os.access(os.path.join(ROOT, "layout/DEBIAN/postinst"), os.X_OK):
            errors += fail(f"postinst not executable for {scheme}")
        if prefix and "$PREFIX/Library" not in script:
            errors += fail(f"rootless postinst lacks prefixed path for {scheme}")
        expected_arch = "iphoneos-arm64" if prefix else "iphoneos-arm64e"
        if f"Architecture: {expected_arch}" not in open(os.path.join(ROOT, "control")).read():
            errors += fail(f"wrong generated architecture for {scheme}")
    print("ok maintainer scripts both schemes")
    subprocess.run(["./tools/generate_maintainer_scripts.sh", "roothide"], cwd=ROOT, check=True)

    for base, _, names in os.walk(ROOT):
        if "/reference/" in base or "/vendor/" in base or "/evidence/" in base:
            continue
        for name in names:
            if not name.endswith((".m", ".h", ".xm", ".py", ".sh")):
                continue
            path = os.path.join(base, name)
            text = open(path, encoding="utf-8").read()
            if name.endswith((".m", ".h", ".xm")):
                if text.count("{") != text.count("}"):
                    errors += fail(f"brace mismatch {path}")
                if text.count("(") != text.count(")"):
                    errors += fail(f"paren mismatch {path}")
                if "@interface" in text and "@end" not in text:
                    errors += fail(f"missing @end {path}")
            if name in ("Tweak.xm", "PXCloneMenu.m", "PXCloneAccountsController.m") and \
                    "/var/mobile/Library/Preferences/com.niubiprass.clonex.plist" in text:
                errors += fail(f"real var prefs hardcoded in {path}")
    print("ok structural guards")

    result = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py"],
                            cwd=ROOT, capture_output=True, text=True,
                            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
    if result.returncode != 0:
        print(result.stderr[-2000:])
        errors += fail("host tests")
    else:
        print("ok host tests", result.stderr.strip().splitlines()[-3])

    control = open(os.path.join(ROOT, "control")).read()
    if "Architecture: __ARCH__" in control:
        errors += fail("control placeholder not expanded")
    for field in ("Package:", "Version:", "Architecture:", "Depends:"):
        if field not in control:
            errors += fail(f"control missing {field}")
    print("ok control")

    if errors:
        print(f"\n{errors} FAILURE(S)")
        return 1
    print("\nALL LOCAL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())

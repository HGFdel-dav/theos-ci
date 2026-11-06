#!/usr/bin/env python3
"""Whole-project local gate. Read-only except temporary scheme checks."""
import hashlib
import os
import plistlib
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEB = os.environ.get("BASELINE_DEB", "/tmp/parallelx-alpha391-bcca9307.deb")
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
        errors += fail("exact baseline DEB missing; set BASELINE_DEB before validation")

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
        errors += fail("cannot compare vendor without the exact baseline DEB")

    for rel in ["layout/DEBIAN/postinst.in",
                "layout/Library/PreferenceBundles/ParallelXPrefs.bundle/Root.plist",
                "ParallelXPrefsUI.plist", "ParallelXClone.plist"]:
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

    # A local that is only ever declared is a hard error in the CI build
    # (-Werror,-Wunused-variable). Catch the cheap cases here rather than
    # spending a build round on them. The pattern is deliberately narrow: a
    # real type token, the declaration on one line (no \s, which would span
    # lines), and a camelCase name, so exported constants and plain
    # assignments are never reported.
    import re
    local_decl = re.compile(
        r"(?m)^[ \t]*(?:static[ \t]+)?(?:const[ \t]+)?"
        r"(?:[A-Z][A-Za-z0-9_]*(?:<[^>]*>)?|id|BOOL|SEL|IMP|Class|Method)"
        r"(?:[ \t]+\*?[ \t]*|\*[ \t]*)([a-z][A-Za-z0-9_]*)[ \t]*=")
    lint_targets = [os.path.join(ROOT, "Tweak.xm")]
    for sub in ("Common", "Prefs"):
        directory = os.path.join(ROOT, sub)
        if os.path.isdir(directory):
            lint_targets += [os.path.join(directory, name)
                             for name in sorted(os.listdir(directory)) if name.endswith(".m")]

    def unused_locals(path, text):
        found = []
        for name in set(local_decl.findall(text)):
            if len(re.findall(r"\b%s\b" % re.escape(name), text)) < 2:
                found.append(name)
        return sorted(found)

    probe = "void f(void) {\n    NSString *unusedProbe = nil;\n}\n"
    if unused_locals("probe.m", probe) != ["unusedProbe"]:
        errors += fail("unused-local lint does not detect its own probe")
    else:
        for path in lint_targets:
            for name in unused_locals(path, open(path, encoding="utf-8").read()):
                errors += fail(f"unused local {name} in {os.path.relpath(path, ROOT)}")
        print("ok unused locals")

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

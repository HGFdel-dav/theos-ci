#!/usr/bin/env python3
"""Whole-project local gate. Read-only except temporary scheme checks."""
import argparse
import hashlib
import json
import os
import plistlib
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEB = os.environ.get("BASELINE_DEB", "/var/minis/shared/ParallelX-alpha451-clone0104-20261123/evidence/alpha451-original.deb")
MANIFEST_PATH = os.path.join(ROOT, "tools/baseline-alpha451.json")
with open(MANIFEST_PATH, encoding="utf-8") as manifest_file:
    BASELINE = json.load(manifest_file)
VENDOR = os.path.join(ROOT, BASELINE["vendor_root"])


def sha(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fail(message):
    print("FAIL", message)
    return 1


def deb_field(package, field):
    return subprocess.check_output(["dpkg-deb", "-f", package, field], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pinned-vendor", action="store_true",
                        help="CI: compare every vendor file to the manifest from the verified source DEB")
    args = parser.parse_args()
    if args.pinned_vendor and "BASELINE_DEB" in os.environ:
        parser.error("--pinned-vendor does not accept a DEB override; omit it to verify the full DEB")
    errors = 0
    baseline_fields = BASELINE["baseline"]
    has_deb = not args.pinned_vendor and os.path.isfile(DEB)
    if args.pinned_vendor:
        print("CI pinned alpha451 payload mode; source archive not present on the runner", baseline_fields["deb_sha256"])
    elif has_deb:
        digest = sha(DEB)
        if digest != baseline_fields["deb_sha256"]:
            errors += fail(f"baseline deb hash mismatch: {digest}")
        else:
            print("ok exact baseline deb", digest)
        metadata_errors = errors
        for field, key in (("Package", "package"), ("Version", "version"),
                           ("Architecture", "architecture"), ("Depends", "depends")):
            actual = deb_field(DEB, field)
            if actual != baseline_fields[key]:
                errors += fail(f"baseline {field} mismatch: {actual}")
        if errors == metadata_errors:
            print("ok baseline package metadata")
    else:
        errors += fail("exact baseline DEB missing; set BASELINE_DEB to the supplied alpha451 package")

    expected_payload = BASELINE["payload_sha256"]
    payload_errors = errors
    vendor_files = []
    for base, _, names in os.walk(VENDOR):
        for name in names:
            vendor_files.append(os.path.relpath(os.path.join(base, name), VENDOR))
    vendor_files.sort()
    if vendor_files != sorted(expected_payload):
        errors += fail("vendor file set differs from exact alpha451 source manifest")
    for rel, expected in sorted(expected_payload.items()):
        path = os.path.join(VENDOR, rel)
        if not os.path.isfile(path):
            errors += fail(f"vendor source missing {rel}")
        elif sha(path) != expected:
            errors += fail(f"vendor source hash mismatch {rel}")
    if errors == payload_errors:
        print("ok source payload manifest", len(expected_payload), "files")

    if has_deb:
        with tempfile.TemporaryDirectory() as temp:
            try:
                extract_errors = errors
                subprocess.run(["dpkg-deb", "-x", DEB, temp], check=True)
                extracted = []
                for base, _, names in os.walk(temp):
                    for name in names:
                        extracted.append(os.path.relpath(os.path.join(base, name), temp))
                extracted.sort()
                if extracted != sorted(expected_payload):
                    errors += fail("baseline DEB payload file set differs from source manifest")
                for rel, expected in sorted(expected_payload.items()):
                    path = os.path.join(temp, rel)
                    if not os.path.isfile(path):
                        errors += fail(f"baseline DEB payload missing {rel}")
                    elif sha(path) != expected:
                        errors += fail(f"baseline DEB payload mismatch {rel}")
                if errors == extract_errors:
                    print("ok baseline DEB payload matches manifest")
            except subprocess.CalledProcessError as exc:
                errors += fail(f"cannot extract baseline DEB: {exc}")

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

    # Same class of build break: -Werror,-Wunused-function for a static
    # function nobody calls. A name that occurs exactly once in the file can
    # only be its own definition.
    static_fn = re.compile(r"(?m)^[ \t]*static[ \t][^;{\n]*?\b([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(")

    def unused_functions(text):
        return sorted(name for name in set(static_fn.findall(text))
                      if len(re.findall(r"\b%s\b" % re.escape(name), text)) < 2
                      and name not in ("void", "int", "BOOL", "id", "instancetype"))

    probe = "static BOOL PXDeadProbe(void) { return YES; }\n"
    if unused_functions(probe) != ["PXDeadProbe"]:
        errors += fail("unused-function lint does not detect its own probe")
    else:
        for path in lint_targets:
            for name in unused_functions(open(path, encoding="utf-8").read()):
                errors += fail(f"unused function {name} in {os.path.relpath(path, ROOT)}")
        print("ok unused functions")

    # No script may hardcode a build version other than the one in control;
    # that is how the packaging check ended up looking for the previous DEB.
    import glob
    version = None
    for line in open(os.path.join(ROOT, "control"), encoding="utf-8"):
        if line.startswith("Version:"):
            version = line.split(":", 1)[1].strip()
    hardcoded = re.compile(r"\d+\.\d+\.\d+~[A-Za-z0-9.+-]*clone[0-9][0-9.]*")
    for path in sorted(glob.glob(os.path.join(ROOT, "tools", "*.py")) +
                       glob.glob(os.path.join(ROOT, "tests", "*.py"))):
        text = open(path, encoding="utf-8").read()
        for literal in set(hardcoded.findall(text)):
            if literal != version:
                errors += fail(f"stale version {literal} in {os.path.relpath(path, ROOT)}")
    print("ok version literals")

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

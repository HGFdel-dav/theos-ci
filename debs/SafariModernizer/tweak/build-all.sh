#!/bin/sh
# Compatibility rebuild: native RootHide only, never a renamed rootless binary.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$(uname -s)" != Darwin ]; then
    echo 'iOS compilation is refused on iSH/Linux.' >&2
    exit 1
fi
: "${THEOS:?Set THEOS to the pinned roothide/theos checkout}"
: "${DEVELOPER_DIR:?Set DEVELOPER_DIR to the approved Xcode 16.4}"
xcrun clang --version | grep 'Apple clang'
xcodebuild -version | grep '^Xcode 16\.4$'
python3 "$ROOT/tools/check_sdk.py" "$THEOS/sdks/iPhoneOS15.5.sdk"
python3 "$ROOT/tools/check.py" --headers
cd "$ROOT/tweak"
make clean
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
set -- packages/*.deb
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    echo 'Expected exactly one newly built compatibility package.' >&2
    exit 1
fi
mkdir -p "$ROOT/notes"
python3 "$ROOT/tools/verify_deb.py" "$1" --json "$ROOT/notes/package-verification.json"

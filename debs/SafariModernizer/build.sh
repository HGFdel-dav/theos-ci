#!/bin/sh
# Unofficial RootHide compatibility rebuild. Never compile iOS code inside iSH.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$(uname -s)" != Darwin ]; then
    echo 'iOS build requires the approved macOS CI host; local iSH is checks-only.' >&2
    exit 1
fi
python3 "$ROOT/tools/check.py"
sh "$ROOT/tools/prepare_web.sh" --install
sh "$ROOT/tweak/build-all.sh"

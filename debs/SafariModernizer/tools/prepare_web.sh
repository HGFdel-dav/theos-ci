#!/bin/sh
# Web assets only: this script never invokes an iOS compiler or installs a tweak.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT/web"
if [ "${1:-}" = "--install" ]; then
    # Lockfile integrity is checked by npm; do not execute dependency install scripts.
    npm ci --ignore-scripts --no-audit --no-fund
elif [ ! -f node_modules/.package-lock.json ]; then
    echo 'Missing complete npm dependencies; run prepare_web.sh --install.' >&2
    exit 1
fi
SM_IOS=15 npm run build
npm test
cd "$ROOT/tweak"
python3 embed.py ../web/polyfill.min.js polyfill.h polyfill_js
python3 embed.py ../web/smfix.min.js smfix.h smfix_js
python3 "$ROOT/tools/check.py" --headers

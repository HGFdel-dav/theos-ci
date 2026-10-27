#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
MENU="$ROOT/pxclone/CXArcMenu.m"
WAKE="$ROOT/pxclone/CXArcWake.m"
PX="${ROOT}/vendor/PX/dylib/ParallelX.dylib"
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -s "$MENU" ] || fail "missing CXArcMenu.m"
[ -s "$WAKE" ] || fail "missing CXArcWake.m"
[ -s "$PX" ] || fail "missing ParallelX.dylib"
strings -a "$PX" | grep -q 'PXPanelIcon' || fail 'vendor has no PXPanelIcon evidence'
strings -a "$PX" | grep -q 'panelWindow' || fail 'vendor has no panelWindow evidence'
grep -Fq 'containsString:@"PXPanelIcon"' "$MENU" || fail 'real icon class selector missing'
! grep -Fq 'PXAppIcon' "$MENU" || fail 'unsupported PXAppIcon fallback remains'
! grep -Fq 'PXIconView' "$MENU" || fail 'unsupported PXIconView fallback remains'
! grep -Fq 'UIImageView.class' "$MENU" || fail 'unsupported UIImageView fallback remains'
grep -Fq 'CXReadPanelWindow(entry)' "$WAKE" || fail 'panelWindow ivar path is not first'
grep -Fq 'class_getInstanceVariable(cls, "panelWindow")' "$WAKE" || fail 'panelWindow ivar lookup missing'
grep -Fq 'end - offset != (ptrdiff_t)sizeof(id)' "$WAKE" || fail 'ivar slot-width guard missing'
grep -Fq 'isKindOfClass:UIWindow.class' "$WAKE" || fail 'window class guard missing'
! grep -Fq 'CXHook.m' "$ROOT/pxclone/CXArcMenu.m" || fail 'scope violation'
! grep -Fq 'CXRemember.m' "$ROOT/pxclone/CXArcWake.m" || fail 'scope violation'
echo 'PASS: PXPanelIcon + panelWindow evidence and minimal ARC path'

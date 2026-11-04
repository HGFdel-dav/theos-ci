#!/bin/sh
set -eu
scheme="${1:-roothide}"
case "$scheme" in
    rootless) prefix="/var/jb"; arch="iphoneos-arm64" ;;
    roothide|"") prefix=""; arch="iphoneos-arm64e" ;;
    *) echo "unknown scheme: $scheme" >&2; exit 1 ;;
esac
sed "s#__ARCH__#${arch}#g" control.in > control
sed "s#__PREFIX__#${prefix}#g" layout/DEBIAN/postinst.in > layout/DEBIAN/postinst
chmod 0755 layout/DEBIAN/postinst

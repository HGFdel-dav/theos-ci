#!/bin/bash
#
# SplitX 打包脚本。
#
# Xcode 构建主 tweak 与偏好设置；脚本另构建最小化的相机 daemon dylib，
# 再按目标越狱环境统一签名并打包。
#
# Usage:
#   ./build.sh [roothide|rootless|rootful] [debug|release]
#
# Schemes:
#   roothide  -> RootHide devkit + libroothide (dynamic jbroot)
#   rootless  -> Theos libroot (standard rootless path resolution)
#   rootful   -> canonical rootful paths
#
set -euo pipefail

cd "$(dirname "$0")"

# --- 固定 SDK：必须是 iPhoneOS15.5，绝不悄悄跟 Xcode 默认版本走 -------------
THEOS="${THEOS:-/opt/theos}"
SDK_VERSION="${SDK_VERSION:-15.5}"
SDK_PATH="${SDK_PATH:-$(xcrun --sdk iphoneos --show-sdk-path)}"
SDK_PLIST="$SDK_PATH/SDKSettings.plist"
if [ ! -d "$SDK_PATH" ]; then
	echo "error: SDK 路径不存在: $SDK_PATH"; exit 1
fi
ACTUAL_SDK="$(plutil -extract Version raw "$SDK_PLIST" 2>/dev/null || true)"
if [ "$ACTUAL_SDK" != "$SDK_VERSION" ]; then
	echo "error: 需要 iPhoneOS$SDK_VERSION SDK，实际是 '$ACTUAL_SDK' ($SDK_PATH)"
	echo "       设置 SDK_PATH 指向 iPhoneOS$SDK_VERSION.sdk 后重试"
	exit 1
fi
MIN_IOS="15.0"

SCHEME="${1:-roothide}"
CONFIG_ARG="${2:-release}"

case "$CONFIG_ARG" in
	debug|Debug)     CONFIGURATION="Debug" ;;
	release|Release) CONFIGURATION="Release" ;;
	*) echo "error: unknown configuration '$CONFIG_ARG' (use debug|release)"; exit 1 ;;
esac

# ---- Per-scheme settings -----------------------------------------------------
POP_ROOTHIDE_LDFLAGS="-lroothide"
POP_ROOTLESS_LDFLAGS=""
POP_SCHEME_DEFS="THEOS_PACKAGE_SCHEME_ROOTHIDE=1"
POP_RPATHS=""
POP_SCHEME_LIBRARY_DIR="$THEOS/vendor/lib/iphone/roothide"
POP_ALTLIST_FRAMEWORK_DIR="$PWD/SplitXPreferences/Frameworks/_roothide"
ARCHS="arm64e"

# Jailbreak environment <-> deb architecture / install prefix mapping:
#   rootful  -> deb iphoneos-arm    prefix /        (absolute install names)
#   rootless -> deb iphoneos-arm64  prefix /var/jb  (@rpath install names)
#   roothide -> deb iphoneos-arm64e prefix /        (randomized jbroot, @loader_path/.jbroot)
# NB: "arm/arm64/arm64e" here are the dpkg Architecture labels, not CPU archs.
#     Binaries are built fat (arm64+arm64e) where possible so the preference
#     bundle loads regardless of whether the host process runs as arm64 or arm64e.
case "$SCHEME" in
	roothide)
		PREFIX=""
		DEB_ARCH="iphoneos-arm64e"
		ARCHS="arm64 arm64e"
		POP_ALTLIST_FRAMEWORK_DIR="$PWD/SplitXPreferences/Frameworks/_roothide"
		;;
	rootless)
		PREFIX="/var/jb"
		DEB_ARCH="iphoneos-arm64"
		ARCHS="arm64 arm64e"
		POP_ROOTHIDE_LDFLAGS=""
		POP_ROOTLESS_LDFLAGS="-lroot"
		POP_SCHEME_DEFS="POP_PACKAGE_SCHEME_ROOTLESS=1"
		POP_SCHEME_LIBRARY_DIR="$THEOS/vendor/lib/iphone/rootless"
		POP_ALTLIST_FRAMEWORK_DIR="$PWD/SplitXPreferences/Frameworks/_rootless"
		# Rootless v2 supports both the conventional and relocated jbroot rpaths.
		POP_RPATHS="/var/jb/usr/lib /var/jb/Library/Frameworks @loader_path/.jbroot/usr/lib @loader_path/.jbroot/Library/Frameworks"
		;;
	rootful)
		PREFIX=""
		DEB_ARCH="iphoneos-arm"
		ARCHS="arm64"
		POP_ROOTHIDE_LDFLAGS=""
		POP_SCHEME_DEFS="POP_PACKAGE_SCHEME_ROOTFUL=1"
		POP_SCHEME_LIBRARY_DIR="$THEOS/vendor/lib"
		POP_ALTLIST_FRAMEWORK_DIR="$PWD/SplitXPreferences/Frameworks"
		POP_RPATHS="/usr/lib /Library/Frameworks"
		;;
	*)
		echo "error: unknown scheme '$SCHEME' (use roothide|rootless|rootful)"
		exit 1
		;;
esac

echo "==> Building SplitX  [scheme=$SCHEME  config=$CONFIGURATION  arch=$ARCHS  deb=$DEB_ARCH]"

# ---- Compile with Xcode ------------------------------------------------------
BUILD_ROOT="$PWD/build"
BUILD_DIR="$BUILD_ROOT/$SCHEME"
PRODUCTS_DIR="$BUILD_DIR/products"
# Build products, derived data, and staging files are temporary. Keep only the
# finished package in packages/ after this script exits, including on failure.
trap 'rm -rf "$BUILD_ROOT"' EXIT
rm -rf "$BUILD_DIR"
mkdir -p "$PRODUCTS_DIR"
DERIVED_DATA_DIR="$BUILD_DIR/derived-data"

XCB_COMMON=(
	-project SplitX.xcodeproj
	-derivedDataPath "$DERIVED_DATA_DIR"
	-configuration "$CONFIGURATION"
	THEOS="$THEOS"
	-sdk iphoneos
	SDKROOT="$SDK_PATH"
	ARCHS="$ARCHS"
	VALID_ARCHS="$ARCHS"
	ONLY_ACTIVE_ARCH=NO
	POP_SCHEME_LIBRARY_DIR="$POP_SCHEME_LIBRARY_DIR"
	POP_ALTLIST_FRAMEWORK_DIR="$POP_ALTLIST_FRAMEWORK_DIR"
	POP_ROOTHIDE_LDFLAGS="$POP_ROOTHIDE_LDFLAGS"
	POP_ROOTLESS_LDFLAGS="$POP_ROOTLESS_LDFLAGS"
	POP_SCHEME_DEFS="$POP_SCHEME_DEFS"
	LD_RUNPATH_SEARCH_PATHS="$POP_RPATHS"
	CONFIGURATION_BUILD_DIR="$PRODUCTS_DIR"
	STRIP_INSTALLED_PRODUCT=YES
	STRIP_STYLE=non-global
	CODE_SIGNING_ALLOWED=NO
	CODE_SIGNING_REQUIRED=NO
)

# SplitX 已在 Xcode 工程中依赖 SplitXPreferences；构建主 scheme
# 会一次生成两个产物，无需先重复构建偏好设置包。
echo "==> xcodebuild scheme SplitX"
xcodebuild -scheme SplitX "${XCB_COMMON[@]}" build

DYLIB="$PRODUCTS_DIR/SplitX.dylib"
CAMERA_DYLIB="$PRODUCTS_DIR/SplitXCamera.dylib"
CAMERA_SOURCE="$PWD/SplitX/POCameraCompatibility.m"
BUNDLE="$PRODUCTS_DIR/SplitXPreferences.bundle"

[ -f "$DYLIB" ]   || { echo "error: $DYLIB not built"; exit 1; }
[ -d "$BUNDLE" ]  || { echo "error: $BUNDLE not built"; exit 1; }

# 相机兼容只注入媒体 daemon，避免把 SpringBoard 私有依赖带入 mediaserverd。
echo "==> Building SplitXCamera.dylib"
CAMERA_ARCH_OUTPUTS=()
CAMERA_RPATH_FLAGS=""
for RPATH in $POP_RPATHS; do
	CAMERA_RPATH_FLAGS="$CAMERA_RPATH_FLAGS -Wl,-rpath,$RPATH"
done
for ARCH in $ARCHS; do
	CAMERA_ARCH_DYLIB="$BUILD_DIR/SplitXCamera-$ARCH.dylib"
	xcrun clang \
		-arch "$ARCH" \
		-isysroot "$SDK_PATH" \
		-miphoneos-version-min="$MIN_IOS" \
		-Os -fobjc-arc -dynamiclib \
		-L"$POP_SCHEME_LIBRARY_DIR" -L"$THEOS/vendor/lib" \
		$CAMERA_RPATH_FLAGS \
		-Wl,-dead_strip \
		-Wl,-install_name,/Library/MobileSubstrate/DynamicLibraries/SplitXCamera.dylib \
		-lsubstrate -framework Foundation \
		"$CAMERA_SOURCE" -o "$CAMERA_ARCH_DYLIB"
	CAMERA_ARCH_OUTPUTS+=("$CAMERA_ARCH_DYLIB")
done
if [ "${#CAMERA_ARCH_OUTPUTS[@]}" -eq 1 ]; then
	cp "${CAMERA_ARCH_OUTPUTS[0]}" "$CAMERA_DYLIB"
else
	lipo -create "${CAMERA_ARCH_OUTPUTS[@]}" -output "$CAMERA_DYLIB"
fi

# ---- Assemble the package staging tree ---------------------------------------
STAGE="$BUILD_DIR/stage"
rm -rf "$STAGE"
ROOT="$STAGE$PREFIX"

# Tweak dylib + MobileSubstrate filter
mkdir -p "$ROOT/Library/MobileSubstrate/DynamicLibraries"
cp "$DYLIB" "$ROOT/Library/MobileSubstrate/DynamicLibraries/SplitX.dylib"
cp "$CAMERA_DYLIB" "$ROOT/Library/MobileSubstrate/DynamicLibraries/SplitXCamera.dylib"
cp "SplitX/Package/Library/MobileSubstrate/DynamicLibraries/SplitX.plist" \
   "$ROOT/Library/MobileSubstrate/DynamicLibraries/SplitX.plist"
cp "SplitX/Package/Library/MobileSubstrate/DynamicLibraries/SplitXCamera.plist" \
   "$ROOT/Library/MobileSubstrate/DynamicLibraries/SplitXCamera.plist"

# Preference bundle (built) + bundled resources
mkdir -p "$ROOT/Library/PreferenceBundles"
cp -R "$BUNDLE" "$ROOT/Library/PreferenceBundles/SplitXPreferences.bundle"
SRC_BUNDLE="SplitXPreferences/Package/Library/PreferenceBundles/SplitXPreferences.bundle"
# copy runtime resources (images + settings spec), skip stale binary/signature/frameworks
find "$SRC_BUNDLE" -maxdepth 1 -type f \
	! -name 'SplitXPreferences' ! -name 'Info.plist' \
	-exec cp {} "$ROOT/Library/PreferenceBundles/SplitXPreferences.bundle/" \;
# Keep localized .lproj directories with the preference bundle. The tweak and
# Preferences controller both resolve their strings from this installed bundle.
find "$SRC_BUNDLE" -maxdepth 1 -type d -name '*.lproj' \
	-exec cp -R {} "$ROOT/Library/PreferenceBundles/SplitXPreferences.bundle/" \;
rm -rf "$ROOT/Library/PreferenceBundles/SplitXPreferences.bundle/_CodeSignature"

# Strip Xcode-injected keys that break preference-bundle loading by the Settings app.
BUNDLE_PLIST="$ROOT/Library/PreferenceBundles/SplitXPreferences.bundle/Info.plist"
if [ -f "$BUNDLE_PLIST" ]; then
	plutil -remove UIRequiredDeviceCapabilities "$BUNDLE_PLIST" 2>/dev/null || true
fi

# PreferenceLoader entry
mkdir -p "$ROOT/Library/PreferenceLoader/Preferences"
cp "SplitXPreferences/Package/Library/PreferenceLoader/Preferences/SplitXPreferences.plist" \
   "$ROOT/Library/PreferenceLoader/Preferences/SplitXPreferences.plist"

command -v codesign >/dev/null 2>&1 || {
	echo "error: codesign is required to sign jailbreak binaries"
	exit 1
}
echo "==> codesign - (ad-hoc signing)"
for SIGN_TARGET in \
	"$ROOT/Library/MobileSubstrate/DynamicLibraries/SplitX.dylib" \
	"$ROOT/Library/MobileSubstrate/DynamicLibraries/SplitXCamera.dylib" \
	"$ROOT/Library/PreferenceBundles/SplitXPreferences.bundle"; do
	codesign --force --sign - --timestamp=none "$SIGN_TARGET"
	codesign --verify --strict "$SIGN_TARGET"
done

# ---- DEBIAN control ----------------------------------------------------------
mkdir -p "$STAGE/DEBIAN"
sed -E "s/^Architecture:.*/Architecture: $DEB_ARCH/" \
	"SplitX/Package/DEBIAN/control" > "$STAGE/DEBIAN/control"
if [ -f "SplitX/Package/DEBIAN/postinst" ]; then
	cp "SplitX/Package/DEBIAN/postinst" "$STAGE/DEBIAN/postinst"
fi

# ---- Build the .deb ----------------------------------------------------------
mkdir -p packages
VERSION="$(sed -n 's/^Version:[[:space:]]*//p' "$STAGE/DEBIAN/control" | tr -d '\r')"
PKGID="$(sed -n 's/^Package:[[:space:]]*//p' "$STAGE/DEBIAN/control" | tr -d '\r')"
DEB="packages/${PKGID}_${VERSION}_${DEB_ARCH}.deb"

find "$STAGE" -name '.DS_Store' -delete
chmod -R 0755 "$STAGE/DEBIAN"
dpkg-deb -Zgzip --root-owner-group -b "$STAGE" "$DEB"

echo "==> Done: $DEB"

#!/usr/bin/env bash
# insulation 二进制修补 + ldid 重签(SHA256) + 打包（云端 macos runner / 本地一致）
set -euo pipefail
cd "$(dirname "$0")"

command -v python3 >/dev/null || { echo '缺 python3'; exit 1; }
command -v ldid    >/dev/null || { echo '缺 ldid'; exit 1; }

rm -rf build stage
mkdir -p build stage

echo '--- 1. 修补 8 条指令 ---'
python3 patch.py original/insulation.dylib build/insulation.dylib

echo '--- 2. ad-hoc 重签（必须含 SHA256 CD；漏签= SIGKILL-CODESIGNING 崩） ---'
# ldid 默认可能只给 SHA1（slot0）或 SHA1+SHA256 两张 CD；iOS 15 arm64e 必须有 SHA256 CD。
# 逐个候选参数试，谁的产物通过 verify_sig.py（等价内核装载校验）就用谁。
SIGNED=0
for FLAGS in "-Hsha256" "-Hsha256 -Icom.be-huge.insulation" ""; do
  rm -f build/insulation.dylib
  python3 patch.py original/insulation.dylib build/insulation.dylib >/dev/null
  if ldid $FLAGS -S build/insulation.dylib >/dev/null 2>&1; then
    if python3 verify_sig.py build/insulation.dylib; then
      echo "  ✓ ldid 参数: '${FLAGS:-默认}' 产出合规 SHA256 签名"
      SIGNED=1
      break
    fi
  fi
  echo "  · ldid '${FLAGS:-默认}' 未通过校验，换下一个"
done
[ "$SIGNED" = 1 ] || { echo 'ldid 无法产出 iOS 15 可接受的 SHA256 签名'; exit 1; }

echo '--- 3. 逐页哈希自校验（等价内核 AMFI 装载检查） ---'
python3 verify_sig.py build/insulation.dylib

echo '--- 4. 组装 stage ---'
cp -R payload/. stage/
mkdir -p stage/DEBIAN
cp control postinst stage/DEBIAN/
cp build/insulation.dylib stage/Library/MobileSubstrate/DynamicLibraries/insulation.dylib
find stage -type d -exec chmod 755 {} \;
find stage -type f -exec chmod 644 {} \;
chmod 755 stage/DEBIAN/postinst
chmod 755 stage/Library/MobileSubstrate/DynamicLibraries/insulation.dylib
chmod 755 stage/usr/bin/insulationctl
chmod 755 stage/Library/ControlCenter/Bundles/InsulationCC.bundle/InsulationCC
chmod 755 stage/Library/PreferenceBundles/InsulationPrefs.bundle/InsulationPrefs

echo '--- 5. 打包 ---'
DEB=com.be-huge.insulation_0.1.38.1-fix2_iphoneos-arm64e.deb
python3 mkdeb.py stage "$DEB"
ls -l "$DEB"

echo '--- 6. 噪声清理 ---'
rm -rf build stage

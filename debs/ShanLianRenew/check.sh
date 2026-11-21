#!/bin/sh
# 本地静态自检（iSH 不能编 iOS，这里只查结构性问题）
set -u
cd "$(dirname "$0")"
FAIL=0
say() { printf '%s\n' "$*"; }
bad() { say "FAIL $*"; FAIL=1; }

for f in Makefile control Tweak.xm SLRenewPaths.h SLRenewPaths.m SLRenewState.h SLRenewState.m \
         SLSigner.h SLSigner.m SLHttp.h SLHttp.m \
         layout/Library/MobileSubstrate/DynamicLibraries/ShanLianRenew.plist; do
  [ -f "$f" ] || bad "缺文件 $f"
done

python3 - <<'EOF' || FAIL=1
import plistlib,glob,sys
for f in glob.glob('layout/**/*.plist',recursive=True):
    try: plistlib.load(open(f,'rb'))
    except Exception as e: print('FAIL bad plist',f,e); sys.exit(1)
print('ok plists')
EOF

for f in *.m *.xm; do
  python3 - "$f" <<'EOF' || FAIL=1
import sys, re
s = open(sys.argv[1]).read()
s = re.sub(r'\.', 'x', s)
s = re.sub(r'"[^"\n]*"', '""', s)
s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
s = re.sub(r'//[^\n]*', '', s)
if s.count('{') != s.count('}') or s.count('(') != s.count(')') or s.count('[') != s.count(']'):
    print('FAIL unbalanced', sys.argv[1]); sys.exit(1)
EOF
done

grep -q 'lightningxvpnsymkey' SLSigner.m || bad '缺密钥账户'
grep -q 'slfillInviteCodefe' Tweak.xm || bad '缺填码接口'
grep -q 'slgetUserInfogo' Tweak.xm || bad '缺读到期接口'
grep -q 'SLPhaseNeedFill' Tweak.xm || bad '缺状态机'
grep -q 'isUILocked' Tweak.xm || bad '缺锁屏判断'
grep -q 'notify_post' Tweak.xm || bad '缺内部通知投递'
grep -q 'com.apple.springboard' layout/Library/MobileSubstrate/DynamicLibraries/ShanLianRenew.plist || bad '缺 SpringBoard 过滤'
grep -q '88888888' SLRenewState.m || bad '缺默认码'
grep -q 'PreferenceBundles' Makefile && bad '仍引用已删除的面板'
grep -q 'com.minis.shanlianrenew.log' SLRenewPaths.m || bad '缺文件日志'
grep -q 'calib try' SLHttp.m || bad '缺签名校准日志'
grep -q 'tick due dl_in=' Tweak.xm || bad '缺到期判据日志'
grep -q 'renew due -> start' Tweak.xm || bad '缺点击续期日志'
grep -q 'rolled back' Tweak.xm || bad '缺回滚日志'

if [ "$FAIL" = 0 ]; then say 'ALL STATIC CHECKS PASS'; else say 'STATIC CHECKS FAILED'; fi
exit $FAIL

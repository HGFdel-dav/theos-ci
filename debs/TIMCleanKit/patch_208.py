#!/usr/bin/env python3
# TIMCleanKit 2.0.8 = 2.0.7（撤回判定修复）+ 红包专属类型过滤
#  真机：别人的专属红包（"仅Hello zqbb可领取"）redType=1 也被自动点击弹窗；
#  普通红包 redType=2。加规则：redType==1 一律跳过（不点击、不弹窗）。
BASE='/var/minis/shared/theos-ci/debs/TIMCleanKit/TIMCleanKit'
def read(p): return open(p,encoding='utf-8').read()
def write(p,s): open(p,'w',encoding='utf-8').write(s)

p=BASE+'/Tweak.xm'; s=read(p)
old='''    TKRedEvent([NSString stringWithFormat:@"红包到达 redType=%lld amount=%lld分",redType0,amount0]);
    if(!prefBool(kEnabled,YES)||!prefBool(kRedPacket,YES)||!prefBool(kAutoRed,YES)){TKRedEvent(@"跳过:功能或自动领取开关未开启");return;}'''
assert s.count(old)==1,'queue=%d'%s.count(old)
s=s.replace(old,'''    TKRedEvent([NSString stringWithFormat:@"红包到达 redType=%lld amount=%lld分",redType0,amount0]);
    /* 2.0.8: redType==1 = 专属/非公开红包（真机："仅Hello zqbb可领取"的专属红包 redType=1，普通红包 redType=2）。
       自动领取一律跳过——点开也领不到，只会弹窗打扰。 */
    if(redType0==1){TKRedEvent(@"跳过:专属/非公开红包(redType=1,不点击)");return;}
    if(!prefBool(kEnabled,YES)||!prefBool(kRedPacket,YES)||!prefBool(kAutoRed,YES)){TKRedEvent(@"跳过:功能或自动领取开关未开启");return;}''')
assert s.count('@"version":@"2.0.7"')==2,'ver=%d'%s.count('@"version":@"2.0.7"')
s=s.replace('@"version":@"2.0.7"','"version":@"2.0.8"'.join(['@','']))
write(p,s)
print('1. 红包过滤+版本 OK')
p=BASE+'/TKSettingsUI.h'; s=read(p)
s=s.replace('@"2.0.7 · 双指长按唤醒"','"2.0.8 · 双指长按唤醒"'.join(['@','']))
s=s.replace('?:@"2.0.7"','?:@"2.0.8"')
write(p,s)
p='/var/minis/shared/theos-ci/debs/TIMCleanKit/control'
s=read(p); s=s.replace('Version: 2.0.7','Version: 2.0.8'); write(p,s)
print('2. UI/control 版本 OK')
print('ALL PATCHES APPLIED (2.0.8)')
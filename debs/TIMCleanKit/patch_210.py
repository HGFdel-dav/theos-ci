#!/usr/bin/env python3
# TIMCleanKit 2.1.0 = 2.0.9 + 修闪退：recallTime 无限递归
#  闪退根因：TKWasRecalled 里 TKScalar(record,@"recallTime") 走 getter → 被 hook 成 AR_recallTime
#  → AR_recallTime 内部又调 TKWasRecalled → 再读 recallTime → 无限递归 → 栈溢出 → TIM 闪退。
#  修法：新增 TKRecordRecallTimeRaw（用 hook 前的原 IMP 直读，不经过 NSInvocation/hook），
#        TKWasRecalled 与 onMsgRecall 校验一律走 Raw 版；TKWasRecalled 不再写标记（只判定）。
BASE='/var/minis/shared/theos-ci/debs/TIMCleanKit/TIMCleanKit'
def read(p): return open(p,encoding='utf-8').read()
def write(p,s): open(p,'w',encoding='utf-8').write(s)

p=BASE+'/Tweak.xm'; s=read(p)

# 1. 新增 Raw 读函数（放在 TKMessageIdentity 之后、TKWasRecalled 之前）
old='''static NSString *TKMessageIdentity(id record) {
    NSArray *keys=TKMessageIdentityKeys(record);
    return keys.firstObject;
}'''
assert s.count(old)==1,'identity=%d'%s.count(old)
s=s.replace(old,'''static NSString *TKMessageIdentity(id record) {
    NSArray *keys=TKMessageIdentityKeys(record);
    return keys.firstObject;
}
/* 2.1.0: 直接读"撤回时间"，走 hook 之前的原 IMP。
   绝不能用 TKScalar/常规 getter 读——recallTime getter 被 AR_recallTime 替换，
   而 AR_recallTime 又调用 TKWasRecalled，会与本函数形成无限递归（2.0.9 闪退根因）。 */
static long long TKRecordRecallTimeRaw(id record) {
    static SEL sel;static dispatch_once_t once;
    dispatch_once(&once,^{sel=NSSelectorFromString(@"recallTime");});
    IMP orig=OrigIMP(@"OCMsgRecord",sel);
    if(!orig)return 0;
    return ((long long(*)(id,SEL))orig)(record,sel);
}''')

# 2. TKWasRecalled 改用 Raw、不写标记
old='''    /* 2.0.9: 直接看 TIM 自己写在 record 上的撤回时间——1 小时内写入的视为真撤回；
       历史同步的旧值不认（避免把很早以前正常消息上的字段当撤回）。 */
    long long rt=TKScalar(record,@"recallTime","q");
    if(rt>0 && rt>(long long)[[NSDate date] timeIntervalSince1970]-3600) {TKMarkRecall(record);return YES;}'''
assert s.count(old)==1,'rt=%d'%s.count(old)
s=s.replace(old,'''    /* 2.0.9: 直接看 TIM 自己写在 record 上的撤回时间——1 小时内写入的视为真撤回；
       历史同步的旧值不认（避免把很早以前正常消息上的字段当撤回）。
       2.1.0: 用 Raw 读（走原 IMP，避免与 AR_recallTime hook 形成无限递归）；只判定不写标记。 */
    long long rt=TKRecordRecallTimeRaw(record);
    if(rt>0 && rt>(long long)[[NSDate date] timeIntervalSince1970]-3600)return YES;''')

assert s.count('@"version":@"2.0.9"')==2,'ver=%d'%s.count('@"version":@"2.0.9"')
s=s.replace('@"version":@"2.0.9"','"version":@"2.1.0"'.join(['@','']))
write(p,s)
print('1-2. Raw读+版本 OK')

# 3. onMsgRecall 校验同样用 Raw
p=BASE+'/TKMessageBridge.h'; s=read(p)
old='                long long rt=TKScalar(record,@"recallTime","q");'
assert s.count(old)==1,'bridge-rt=%d'%s.count(old)
s=s.replace(old,'                long long rt=TKRecordRecallTimeRaw(record); /* 2.1.0: Raw 读，防递归 */')
write(p,s)
print('3. onMsgRecall Raw OK')

# 4. 版本
p=BASE+'/TKSettingsUI.h'; s=read(p)
s=s.replace('@"2.0.9 · 双指长按唤醒"','"2.1.0 · 双指长按唤醒"'.join(['@','']))
s=s.replace('?:@"2.0.9"','?:@"2.1.0"')
write(p,s)
p='/var/minis/shared/theos-ci/debs/TIMCleanKit/control'
s=read(p); s=s.replace('Version: 2.0.9','Version: 2.1.0'); write(p,s)
print('4. 版本 2.1.0 OK')
print('ALL PATCHES APPLIED (2.1.0)')
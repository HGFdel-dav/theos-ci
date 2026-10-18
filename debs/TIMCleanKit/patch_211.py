#!/usr/bin/env python3
# TIMCleanKit 2.1.1 = 2.1.0 + 修误标（相邻消息被一起标）
#  真机：你是哥姬只撤回"第二句"，但"第二句""第三句"都带标签。
#  原因：TIM 撤回处理会给多条消息批量写 recallTime 同值（此前日志 4 条同值实锤），
#       按"recallTime≈now"打标必然误标邻居。
#  修法：标签只由撤回通知(onMsgRecall)的 seq 匹配驱动（2.0.6 实测 177→第二句、182→第三句 均准确）；
#        setRecallTime≈now 仍然回写0拦截（内容不消失），但不再打标；recallTime 字段只记录不参与判定。
BASE='/var/minis/shared/theos-ci/debs/TIMCleanKit/TIMCleanKit'
def read(p): return open(p,encoding='utf-8').read()
def write(p,s): open(p,'w',encoding='utf-8').write(s)

p=BASE+'/Tweak.xm'; s=read(p)

# 1. AR_setRecallTime：只拦截不标记
old='''        if(value>now-120) {
            TKMarkRecall(self);
            TKArchiveRecalledRecord(self);
            TKRecallEvent([NSString stringWithFormat:@"setRecallTime≈now 标记:%@",TKRecallTextOf(self)]);
            value=0; /* 确认撤回就拦截——无条件回写0，内容不删 */
            TKRefreshRecallLabels();
        } else if(TKWasRecalled(self)) {'''
assert s.count(old)==1,'setrt=%d'%s.count(old)
s=s.replace(old,'''        if(value>now-120) {
            /* 2.1.1: 只拦截、不打标——TIM 会给多条消息批量写同一时间戳，
               按字段打标会误标未撤回的邻居（真机："第三句"未撤回却带标签）。
               标签统一由 onMsgRecall（撤回通知）的 seq 匹配产生。 */
            TKRecallEvent([NSString stringWithFormat:@"setRecallTime≈now 拦截(不标记):%@",TKRecallTextOf(self)]);
            value=0; /* 确认撤回就拦截——无条件回写0，内容不删 */
            TKRefreshRecallLabels();
        } else if(TKWasRecalled(self)) {''')

# 2. TKWasRecalled：去掉 recallTime 直判
old='''    /* 2.0.9: 直接看 TIM 自己写在 record 上的撤回时间——1 小时内写入的视为真撤回；
       历史同步的旧值不认（避免把很早以前正常消息上的字段当撤回）。
       2.1.0: 用 Raw 读（走原 IMP，避免与 AR_recallTime hook 形成无限递归）；只判定不写标记。 */
    long long rt=TKRecordRecallTimeRaw(record);
    if(rt>0 && rt>(long long)[[NSDate date] timeIntervalSince1970]-3600)return YES;
    TKRecallArchiveCache();'''
assert s.count(old)==1,'wasrecalled=%d'%s.count(old)
s=s.replace(old,'''    /* 2.1.1: 不再按 record.recallTime 直判——TIM 撤回处理会给多条消息写同一时间戳，
       按字段判定会误标未撤回的邻居。只认撤回通知驱动产生的标记（flag/双键集合/归档）。 */
    TKRecallArchiveCache();''')

assert s.count('@"version":@"2.1.0"')==2,'ver=%d'%s.count('@"version":@"2.1.0"')
s=s.replace('@"version":@"2.1.0"','"version":@"2.1.1"'.join(['@','']))
write(p,s)
print('1-2. Tweak.xm OK')

# 3. TKBridgeRecall：seq 匹配即标记（recallTime 只记录）
p=BASE+'/TKMessageBridge.h'; s=read(p)
old='''                long long rt=TKRecordRecallTimeRaw(record); /* 2.1.0: Raw 读，防递归 */
                if(rt>0 && rt>now-3600) {
                    TKMarkRecall(record);TKArchiveRecalledRecord(record);marked=YES;
                    TKRecallEvent([NSString stringWithFormat:@"onMsgRecall 校验标记(recallTime=%lld):%@",rt,TKRecallTextOf(record)]);
                } else {
                    TKRecallEvent([NSString stringWithFormat:@"onMsgRecall seq=%llu 匹配到但recallTime=%lld,不标(防偏移)",seq,rt]);
                }'''
assert s.count(old)==1,'bridge=%d'%s.count(old)
s=s.replace(old,'''                long long rt=TKRecordRecallTimeRaw(record); /* 2.1.0: Raw 读，防递归 */
                /* 2.1.1: 撤回通知的 seq 即被撤回消息的序号（真机 177→第二句、182→第三句 均准确），
                   recallTime 仅记录不拦截判断——TIM 会给多条消息批量写同值，不能作为过滤条件。 */
                TKMarkRecall(record);TKArchiveRecalledRecord(record);marked=YES;
                TKRecallEvent([NSString stringWithFormat:@"onMsgRecall 标记(recallTime=%lld):%@",rt,TKRecallTextOf(record)]);''')
# 去掉不再使用的 now 变量警告风险：now 仍用于无（改成 __attribute__((unused)) 不行，保留变量可能 unused）
old='        long long now=(long long)[[NSDate date] timeIntervalSince1970];\n        [gTKCacheLock lock];NSArray *savedRecords=[gTKMessageCache.allValues copy];[gTKCacheLock unlock];'
assert s.count(old)==1,'nowvar=%d'%s.count(old)
s=s.replace(old,'        [gTKCacheLock lock];NSArray *savedRecords=[gTKMessageCache.allValues copy];[gTKCacheLock unlock];')
write(p,s)
print('3. onMsgRecall 无条件标记 OK')

# 4. 版本
p=BASE+'/TKSettingsUI.h'; s=read(p)
s=s.replace('@"2.1.0 · 双指长按唤醒"','"2.1.1 · 双指长按唤醒"'.join(['@','']))
s=s.replace('?:@"2.1.0"','?:@"2.1.1"')
write(p,s)
p='/var/minis/shared/theos-ci/debs/TIMCleanKit/control'
s=read(p); s=s.replace('Version: 2.1.0','Version: 2.1.1'); write(p,s)
print('4. 版本 2.1.1 OK')
print('ALL PATCHES APPLIED (2.1.1)')
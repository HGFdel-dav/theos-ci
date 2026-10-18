#!/usr/bin/env python3
# TIMCleanKit 2.0.9 = 2.0.8（专属红包过滤+setRecallTime判据）+ 标签显示修复
#  真机 2.0.6 实锤：对方撤回"第二句"→ recallLog 标注成功，但标签从未贴上（labelLog 无记录）；
#  自己撤回"第三句"→ 标签正常。根因链：
#   a) 身份键只用 msgId，缓存 record 与 UI record 可能字段可用性不同 → 标记落不到 UI 对象上；
#   b) 2.0.7 删掉 onMsgRecall 匹配后，对方撤回只能靠 setRecallTime≈now，覆盖不全。
#  修法：msgId+msgSeq 双键；显示时直接看 record 自己的 recallTime（1小时内=真撤回）；
#        onMsgRecall 匹配到 record 后先校验 recallTime 再标记（防 seq 偏移错标）。
BASE='/var/minis/shared/theos-ci/debs/TIMCleanKit/TIMCleanKit'
def read(p): return open(p,encoding='utf-8').read()
def write(p,s): open(p,'w',encoding='utf-8').write(s)

# ===== Tweak.xm =====
p=BASE+'/Tweak.xm'; s=read(p)

old='''static NSString *TKMessageIdentity(id record) {
    NSString *peer=TKObjectCall(record,@"peerUid");long long mid=TKScalar(record,@"msgId","q");
    int chat=(int)TKScalar(record,@"chatType","i");
    return [peer isKindOfClass:NSString.class]&&mid?[NSString stringWithFormat:@"%d:%@:%lld",chat,peer,mid]:nil;
}'''
assert s.count(old)==1,'identity=%d'%s.count(old)
s=s.replace(old,'''/* 2.0.9: 双身份键——msgId 与 msgSeq 各存一个，缓存 record 与 UI record 字段可用性不同时仍能互认
   （真机：对方撤回标注成功但标签贴不上，正是单一 msgId 键在两边对不上） */
static NSArray *TKMessageIdentityKeys(id record) {
    NSString *peer=TKObjectCall(record,@"peerUid");
    if(![peer isKindOfClass:NSString.class]||!peer.length)return nil;
    int chat=(int)TKScalar(record,@"chatType","i");
    long long mid=TKScalar(record,@"msgId","q");
    long long seq=TKScalar(record,@"msgSeq","q");
    NSMutableArray *keys=[NSMutableArray arrayWithCapacity:2];
    if(mid)[keys addObject:[NSString stringWithFormat:@"%d:%@:%lld",chat,peer,mid]];
    if(seq)[keys addObject:[NSString stringWithFormat:@"%d:%@:s%lld",chat,peer,seq]];
    return keys.count?keys:nil;
}
static NSString *TKMessageIdentity(id record) {
    NSArray *keys=TKMessageIdentityKeys(record);
    return keys.firstObject;
}''')

# TKWasRecalled：双键 + recallTime 窗口
old='''static BOOL TKWasRecalled(id record) {
    if(!record)return NO;
    if([objc_getAssociatedObject(record,&kTKRecallFlag) boolValue])return YES;
    NSString *identity=TKMessageIdentity(record);if(!identity)return NO;
    [gTKCacheLock lock];BOOL recalled=[gTKRecalledIDs containsObject:identity];[gTKCacheLock unlock];
    if(recalled)return YES;
    TKRecallArchiveCache(); /* 2.0.7: 懒装载 v>=2 归档 identity（重启后标签保留；旧版归档不复活误标） */
    [gTKCacheLock lock];BOOL recalled2=[gTKRecalledIDs containsObject:identity];[gTKCacheLock unlock];
    return recalled2;
}'''
assert s.count(old)==1,'wasrecalled=%d'%s.count(old)
s=s.replace(old,'''static BOOL TKWasRecalled(id record) {
    if(!record)return NO;
    if([objc_getAssociatedObject(record,&kTKRecallFlag) boolValue])return YES;
    NSArray *keys=TKMessageIdentityKeys(record);
    if(keys.count) {
        [gTKCacheLock lock];BOOL hit=NO;for(NSString *k in keys){if([gTKRecalledIDs containsObject:k]){hit=YES;break;}}[gTKCacheLock unlock];
        if(hit)return YES;
    }
    /* 2.0.9: 直接看 TIM 自己写在 record 上的撤回时间——1 小时内写入的视为真撤回；
       历史同步的旧值不认（避免把很早以前正常消息上的字段当撤回）。 */
    long long rt=TKScalar(record,@"recallTime","q");
    if(rt>0 && rt>(long long)[[NSDate date] timeIntervalSince1970]-3600) {TKMarkRecall(record);return YES;}
    TKRecallArchiveCache(); /* 2.0.7: 懒装载 v>=2 归档 identity（重启后标签保留；旧版归档不复活误标） */
    if(keys.count) {
        [gTKCacheLock lock];BOOL hit2=NO;for(NSString *k in keys){if([gTKRecalledIDs containsObject:k]){hit2=YES;break;}}[gTKCacheLock unlock];
        if(hit2)return YES;
    }
    return NO;
}''')

# TKMarkRecall：双键全加
old='''static void TKMarkRecall(id record) {
    objc_setAssociatedObject(record,&kTKRecallFlag,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSString *identity=TKMessageIdentity(record);if(!identity)return;
    [gTKCacheLock lock];
    if(!gTKRecalledIDs)gTKRecalledIDs=[NSMutableSet new];
    if(![gTKRecalledIDs containsObject:identity]){[gTKRecalledIDs addObject:identity];__atomic_fetch_add(&gTKRecallEvents,1,__ATOMIC_RELAXED);}
    if(gTKRecalledIDs.count>10000)[gTKRecalledIDs removeAllObjects];
    [gTKCacheLock unlock];
}'''
assert s.count(old)==1,'mark=%d'%s.count(old)
s=s.replace(old,'''static void TKMarkRecall(id record) {
    objc_setAssociatedObject(record,&kTKRecallFlag,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSArray *keys=TKMessageIdentityKeys(record);if(!keys.count)return;
    [gTKCacheLock lock];
    if(!gTKRecalledIDs)gTKRecalledIDs=[NSMutableSet new];
    if(![gTKRecalledIDs containsObject:keys.firstObject]){__atomic_fetch_add(&gTKRecallEvents,1,__ATOMIC_RELAXED);}
    for(NSString *k in keys)[gTKRecalledIDs addObject:k]; /* 2.0.9: 双键都记，UI 用哪个都能命中 */
    if(gTKRecalledIDs.count>10000)[gTKRecalledIDs removeAllObjects];
    [gTKCacheLock unlock];
}''')

assert s.count('@"version":@"2.0.8"')==2,'ver=%d'%s.count('@"version":@"2.0.8"')
s=s.replace('@"version":@"2.0.8"','"version":@"2.0.9"'.join(['@','']))
write(p,s)
print('1-3. Tweak.xm identity/wasrecalled/mark OK')

# ===== TKMessageBridge.h：onMsgRecall 校验式标记 =====
p=BASE+'/TKMessageBridge.h'; s=read(p)
old='''    if(TKAntiRecallEnabled()&&[peer isKindOfClass:NSString.class]&&seq) {
        TKRecallFactsLoad();
        NSString *fact=TKRecallFactKey(chat,peer,seq);
        TKRecallFactAdd(fact);
        TKRecallEvent([NSString stringWithFormat:@"onMsgRecall 记录:%@(仅诊断,标记由setRecallTime≈now驱动)",fact]);
    }
    /* 2.0.7: 不再用 seq 在缓存里匹配并标记——真机实锤 seq 与 msgSeq 有偏移，
       "哈哈好的"被撤回却标到"好好说说"。标记统一由 setRecallTime(value≈now) 驱动。
       这里只刷新，让刚被标记的 cell 立刻出标签。 */
    if(TKAntiRecallEnabled())TKRefreshRecallLabels();'''
assert s.count(old)==1,'bridge=%d'%s.count(old)
s=s.replace(old,'''    if(TKAntiRecallEnabled()&&[peer isKindOfClass:NSString.class]&&seq) {
        TKRecallFactsLoad();
        NSString *fact=TKRecallFactKey(chat,peer,seq);
        TKRecallFactAdd(fact);
        /* 2.0.9: 恢复 seq 匹配做补充标记，但必须先用 record 自己的 recallTime 校验——
           撤回通知的 seq 与消息 msgSeq 存在偏移，盲匹配会贴到相邻消息上。 */
        long long now=(long long)[[NSDate date] timeIntervalSince1970];
        [gTKCacheLock lock];NSArray *savedRecords=[gTKMessageCache.allValues copy];[gTKCacheLock unlock];
        BOOL marked=NO;
        for(NSDictionary *saved in savedRecords) {
            id record=saved[@"record"];
            if(record && TKScalar(record,@"chatType","i")==chat && (unsigned long long)TKScalar(record,@"msgSeq","q")==seq && [saved[@"elements"] count]) {
                long long rt=TKScalar(record,@"recallTime","q");
                if(rt>0 && rt>now-3600) {
                    TKMarkRecall(record);TKArchiveRecalledRecord(record);marked=YES;
                    TKRecallEvent([NSString stringWithFormat:@"onMsgRecall 校验标记(recallTime=%lld):%@",rt,TKRecallTextOf(record)]);
                } else {
                    TKRecallEvent([NSString stringWithFormat:@"onMsgRecall seq=%llu 匹配到但recallTime=%lld,不标(防偏移)",seq,rt]);
                }
            }
        }
        if(!marked)TKRecallEvent([NSString stringWithFormat:@"onMsgRecall %@(无校验通过的record)",fact]);
    }
    /* 2.0.7: 标记统一由"撤回时间"驱动；这里刷新让刚标记的 cell 立刻出标签。 */
    if(TKAntiRecallEnabled())TKRefreshRecallLabels();''')
write(p,s)
print('4. onMsgRecall 校验式标记 OK')

# ===== TKCellBridge.h：判定失败日志 + labelLog 16 条 =====
p=BASE+'/TKCellBridge.h'; s=read(p)
old='''    if(!TKAntiRecallEnabled()||!record||!TKWasRecalled(record)) { /* 2.0.3: 确认撤回就一定显示——不再要求有缓存内容 */'''
assert s.count(old)==1,'judge=%d'%s.count(old)
s=s.replace(old,'''    BOOL recalled=record?TKWasRecalled(record):NO; /* 2.0.9: 判定一次，下面日志复用 */
    if(!TKAntiRecallEnabled()||!record||!recalled) { /* 2.0.3: 确认撤回就一定显示——不再要求有缓存内容 */''')
old='''        if(label&&!label.hidden){__atomic_fetch_add(&gTKLabelHidden,1,__ATOMIC_RELAXED);TKLabelDiag([NSString stringWithFormat:@"隐:%@%@",record?TKLabelBriefText(record):@"无记录",highConfidence?@"(高可信)":@"(文本匹配)"]);}
        label.hidden=YES;if(label)label.frame=CGRectZero;return;'''
assert s.count(old)==1,'hide=%d'%s.count(old)
s=s.replace(old,'''        if(label&&!label.hidden){__atomic_fetch_add(&gTKLabelHidden,1,__ATOMIC_RELAXED);TKLabelDiag([NSString stringWithFormat:@"隐:%@%@",record?TKLabelBriefText(record):@"无记录",highConfidence?@"(高可信)":@"(文本匹配)"]);}
        else if(!record&&TKAntiRecallEnabled()) TKLabelDiag(@"未贴:record为空(绑定失败)");
        else if(record&&!recalled) TKLabelDiag([NSString stringWithFormat:@"未贴:未标记 %@%@",TKLabelBriefText(record),highConfidence?@"(高可信)":@"(文本匹配)"]);
        label.hidden=YES;if(label)label.frame=CGRectZero;return;''')
# labelLog 8→16
s=s.replace('while(gTKLabelLog.count>8)','while(gTKLabelLog.count>16)')
write(p,s)
print('5. 判定日志+16条 OK')

# ===== 版本 =====
p=BASE+'/TKSettingsUI.h'; s=read(p)
s=s.replace('@"2.0.8 · 双指长按唤醒"','"2.0.9 · 双指长按唤醒"'.join(['@','']))
s=s.replace('?:@"2.0.8"','?:@"2.0.9"')
write(p,s)
p='/var/minis/shared/theos-ci/debs/TIMCleanKit/control'
s=read(p); s=s.replace('Version: 2.0.8','Version: 2.0.9'); write(p,s)
print('6. 版本 2.0.9 OK')
print('ALL PATCHES APPLIED (2.0.9)')
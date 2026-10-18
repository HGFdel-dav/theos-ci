#!/usr/bin/env python3
# TIMCleanKit 2.0.7：撤回判定改用"TIM 自己的撤回时间字段"（真机实锤 seq 与 msgSeq 有偏移会错标相邻消息）
#  1) setRecallTime(value≈now) = 真撤回 → 标记+无条件回写0（拦截率100%）+归档+刷新；历史值=重放，不标记
#  2) 撤回通知(onMsgRecall)只做诊断与刷新，不再用 seq 匹配标记（错标源）
#  3) TKWasRecalled 去掉 fact(seq) 判定；归档装载 v>=2 的 identity（重启后保留标签，旧误标不复活）
#  4) 版本 2.0.7
BASE='/var/minis/shared/theos-ci/debs/TIMCleanKit/TIMCleanKit'
def read(p): return open(p,encoding='utf-8').read()
def write(p,s): open(p,'w',encoding='utf-8').write(s)

# ===== Tweak.xm =====
p=BASE+'/Tweak.xm'; s=read(p)

# 1. 前向声明补归档函数
old='static void TKRefreshRecallLabels(void); /* 2.0.5: 定义于 TKCellBridge.h（include 在后），此处前向声明 */'
assert s.count(old)==1,'decl=%d'%s.count(old)
s=s.replace(old,'static void TKRefreshRecallLabels(void); /* 2.0.5: 定义于 TKCellBridge.h（include 在后），此处前向声明 */\nstatic void TKArchiveRecalledRecord(id record); /* 2.0.7: 同上，标记时归档撤回内容 */')

# 2. AR_setRecallTime 重构
old='''static void AR_setRecallTime(id self,SEL cmd,long long value) {
    IMP orig=OrigIMP(@"OCMsgRecord",cmd);
    if(value>0 && TKAntiRecallEnabled()) {
        // 2.0.2: setRecallTime(正数) ≠ 被撤回——TIM 正常流程也会写这个字段（真机误报实锤：9条标记仅3条来自撤回通知）。
        // 现在仅对"已由撤回通知标记过"的消息回写0重复拦截；未标记的只记录观察，不再产生标签。
        if(TKWasRecalled(self)) {
            TKRecallEvent([NSString stringWithFormat:@"setRecallTime=%lld(已标记,回写0) %@",value,TKRecallTextOf(self)]);
            if(TKHasCachedContent(self))value=0;
            TKRefreshRecallLabels(); /* 2.0.5: 撤回处理当下立刻刷新可见 cell——不等退出重进 */
        } else if(gTKSetRecallPos<50) {
            gTKSetRecallPos++;
            TKRecallEvent([NSString stringWithFormat:@"setRecallTime=%lld(未标记,仅记录) %@",value,TKRecallTextOf(self)]);
        }
    }
    if(orig)((void(*)(id,SEL,long long))orig)(self,cmd,value);
}'''
assert s.count(old)==1,'setrecall=%d'%s.count(old)
s=s.replace(old,'''static void AR_setRecallTime(id self,SEL cmd,long long value) {
    IMP orig=OrigIMP(@"OCMsgRecord",cmd);
    if(value>0 && TKAntiRecallEnabled()) {
        /* 2.0.7: 主判据=TIM 写入的撤回时间：
           - value≈当前时间 = 真撤回（批量撤回时 TIM 会给多条写同值，一次全部捕获）
           - value=很久以前 = 历史撤回消息的同步重放 → 不标记
           真机实锤 onMsgRecall 的 seq 与消息 msgSeq 有偏移（撤回"哈哈好的"却匹配到"好好说说"），故不再用 seq 判定。 */
        long long now=(long long)[[NSDate date] timeIntervalSince1970];
        if(value>now-120) {
            TKMarkRecall(self);
            TKArchiveRecalledRecord(self);
            TKRecallEvent([NSString stringWithFormat:@"setRecallTime≈now 标记:%@",TKRecallTextOf(self)]);
            value=0; /* 确认撤回就拦截——无条件回写0，内容不删 */
            TKRefreshRecallLabels();
        } else if(TKWasRecalled(self)) {
            TKRecallEvent([NSString stringWithFormat:@"setRecallTime=%lld(已标记,回写0) %@",value,TKRecallTextOf(self)]);
            value=0;
            TKRefreshRecallLabels();
        } else if(gTKSetRecallPos<50) {
            gTKSetRecallPos++;
            TKRecallEvent([NSString stringWithFormat:@"setRecallTime=%lld(历史值,不标记) %@",value,TKRecallTextOf(self)]);
        }
    }
    if(orig)((void(*)(id,SEL,long long))orig)(self,cmd,value);
}''')

# 3. TKWasRecalled 去掉 fact 判定 + 懒装载归档
old='''static BOOL TKWasRecalled(id record) {
    if(!record)return NO;
    if([objc_getAssociatedObject(record,&kTKRecallFlag) boolValue])return YES;
    NSString *identity=TKMessageIdentity(record);
    [gTKCacheLock lock];BOOL recalled=identity&&[gTKRecalledIDs containsObject:identity];[gTKCacheLock unlock];
    if(recalled)return YES;
    TKRecallFactsLoad();
    return TKRecallFactsContains(TKRecallFactKeyOfRecord(record));
}'''
assert s.count(old)==1,'wasRecalled=%d'%s.count(old)
s=s.replace(old,'''static BOOL TKWasRecalled(id record) {
    if(!record)return NO;
    if([objc_getAssociatedObject(record,&kTKRecallFlag) boolValue])return YES;
    NSString *identity=TKMessageIdentity(record);if(!identity)return NO;
    [gTKCacheLock lock];BOOL recalled=[gTKRecalledIDs containsObject:identity];[gTKCacheLock unlock];
    if(recalled)return YES;
    TKRecallArchiveCache(); /* 2.0.7: 懒装载 v>=2 归档 identity（重启后标签保留；旧版归档不复活误标） */
    [gTKCacheLock lock];BOOL recalled2=[gTKRecalledIDs containsObject:identity];[gTKCacheLock unlock];
    return recalled2;
}''')

# 4. TKRecallArchiveCache 装载 v>=2
old='''        if(d)arch=[NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];}
    }@catch(NSException *ignored){}}
    return [arch isKindOfClass:NSDictionary.class]?arch:nil;
}'''
assert s.count(old)==1,'archcache=%d'%s.count(old)
s=s.replace(old,'''        if(d)arch=[NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if([arch isKindOfClass:NSDictionary.class]) {
            [gTKCacheLock lock];
            if(!gTKRecalledIDs)gTKRecalledIDs=[NSMutableSet new];
            for(id key in arch) {
                id item=[arch objectForKey:key];
                if([key isKindOfClass:NSString.class]&&[item isKindOfClass:NSDictionary.class]&&[item[@"v"] intValue]>=2)
                    [gTKRecalledIDs addObject:key];
            }
            [gTKCacheLock unlock];
        }}
    }@catch(NSException *ignored){}}
    return [arch isKindOfClass:NSDictionary.class]?arch:nil;
}''')

# 5. 版本
assert s.count('@"version":@"2.0.6"')==2,'ver=%d'%s.count('@"version":@"2.0.6"')
s=s.replace('@"version":@"2.0.6"','"version":@"2.0.7"'.join(['@','']))
write(p,s)
print('1-5. Tweak.xm OK')

# ===== TKMessageBridge.h：TKBridgeRecall 降级 =====
p=BASE+'/TKMessageBridge.h'; s=read(p)
old='''    if(TKAntiRecallEnabled()&&[peer isKindOfClass:NSString.class]&&seq) {
        /* 2.0.3: 撤回事实独立记录——不依赖缓存是否命中（这正是"三条撤回只标出一条"的原因：通知到了但缓存找不到就不记） */
        TKRecallFactsLoad();
        NSString *fact=TKRecallFactKey(chat,peer,seq);
        TKRecallFactAdd(fact);
        TKRecallEvent([NSString stringWithFormat:@"onMsgRecall 记录:%@",fact]);
        [gTKCacheLock lock];NSArray *savedRecords=[gTKMessageCache.allValues copy];[gTKCacheLock unlock];
        NSMutableArray *seqProbe=[NSMutableArray array]; /* 2.0.5: 未命中时记录缓存里同会话的 msgSeq 样本 */
        for(NSDictionary *saved in savedRecords) {
            id record=saved[@"record"];
            if(seqProbe.count<3 && TKScalar(record,@"chatType","i")==chat) [seqProbe addObject:@((unsigned long long)TKScalar(record,@"msgSeq","q"))];
            /* 2.0.3: 放宽匹配——去掉 peerUid 硬条件（该字段在群/特殊会话不稳定），chatType+msgSeq 已唯一 */
            if(TKScalar(record,@"chatType","i")==chat && (unsigned long long)TKScalar(record,@"msgSeq","q")==seq && [saved[@"elements"] count]) {
                TKMarkRecall(record);TKRestoreRecord(record);blocked=YES;archivedRecord=record;
            }
        }
        if(!blocked)TKRecallEvent([NSString stringWithFormat:@"onMsgRecall 未命中seq=%llu 缓存样本=%@",seq,seqProbe]);
    }
    if(blocked){__atomic_fetch_add(&gTKRecallBlocked,1,__ATOMIC_RELAXED);if(archivedRecord)TKArchiveRecalledRecord(archivedRecord);TKRecallEvent([NSString stringWithFormat:@"onMsgRecall 标注:%@",archivedRecord?TKRecallTextOf(archivedRecord):@""]);}
    else if(TKAntiRecallEnabled()){TKRecallEvent(@"onMsgRecall 无缓存内容(事实已记,刷新后打标)");}
    if(TKAntiRecallEnabled())TKRefreshRecallLabels(); /* 2.0.3: 无条件刷新——没缓存内容的消息也凭撤回事实立刻打标 */
    if(blocked)return;'''
assert s.count(old)==1,'bridge=%d'%s.count(old)
s=s.replace(old,'''    if(TKAntiRecallEnabled()&&[peer isKindOfClass:NSString.class]&&seq) {
        TKRecallFactsLoad();
        NSString *fact=TKRecallFactKey(chat,peer,seq);
        TKRecallFactAdd(fact);
        TKRecallEvent([NSString stringWithFormat:@"onMsgRecall 记录:%@(仅诊断,标记由setRecallTime≈now驱动)",fact]);
    }
    /* 2.0.7: 不再用 seq 在缓存里匹配并标记——真机实锤 seq 与 msgSeq 有偏移，
       "哈哈好的"被撤回却标到"好好说说"。标记统一由 setRecallTime(value≈now) 驱动。
       这里只刷新，让刚被标记的 cell 立刻出标签。 */
    if(TKAntiRecallEnabled())TKRefreshRecallLabels();''')
# 移除 now-unused 变量声明（保持编译无警告）
old='    IMP orig=OrigIMP(TKListenerClass,cmd);BOOL blocked=NO;id archivedRecord=nil; /* 2.0: 供磁盘归档使用 */'
assert s.count(old)==1,'vars=%d'%s.count(old)
s=s.replace(old,'    IMP orig=OrigIMP(TKListenerClass,cmd);')
write(p,s)
print('6. TKBridgeRecall 降级 OK')

# ===== TKCellBridge.h：归档加版本标记 =====
p=BASE+'/TKCellBridge.h'; s=read(p)
old='NSDictionary *context=@{@"text":text?:@"",@"time":@([[NSDate date] timeIntervalSince1970])};'
assert s.count(old)==1,'ctx=%d'%s.count(old)
s=s.replace(old,'NSDictionary *context=@{@"text":text?:@"",@"time":@([[NSDate date] timeIntervalSince1970]),@"v":@2}; /* 2.0.7: v>=2 的归档才参与重启后标签恢复 */')
write(p,s)
print('7. 归档版本标记 OK')

# ===== 版本 =====
p=BASE+'/TKSettingsUI.h'; s=read(p)
s=s.replace('@"2.0.6 · 双指长按唤醒"','"2.0.7 · 双指长按唤醒"'.join(['@','']))
s=s.replace('?:@"2.0.6"','?:@"2.0.7"')
write(p,s)
p='/var/minis/shared/theos-ci/debs/TIMCleanKit/control'
s=read(p); s=s.replace('Version: 2.0.6','Version: 2.0.7'); write(p,s)
print('8. 版本 2.0.7 OK')
print('ALL PATCHES APPLIED (2.0.7)')
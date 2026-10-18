#!/usr/bin/env python3
# TIMCleanKit 2.0.3：撤回显示与"消息内容缓存"解耦
#  1) 撤回事实独立记录：onMsgRecall 一到就记 fact(chat:peer:seq)，不依赖缓存是否命中——当前"三条只标一条"的主因
#  2) 撤回事实持久化（recall-facts.json）——退出重进/重启后仍能打标
#  3) 标签显示条件去掉"必须有缓存内容"——确认撤回就一定显示
#  4) 无缓存时用磁盘归档文本重建内容（跨重启恢复）
#  5) 淘汰缓存不再删撤回标记；缓存 500→1500；匹配放宽（去掉 peerUid 硬条件）
#  6) 版本 2.0.3
BASE='/var/minis/shared/theos-ci/debs/TIMCleanKit/TIMCleanKit'
def read(p): return open(p,encoding='utf-8').read()
def write(p,s): open(p,'w',encoding='utf-8').write(s)

p=BASE+'/Tweak.xm'; s=read(p)

# 1. fact 系统：插在 TKMessageIdentity 之后
anchor='''static NSString *TKMessageIdentity(id record) {
    NSString *peer=TKObjectCall(record,@"peerUid");long long mid=TKScalar(record,@"msgId","q");
    int chat=(int)TKScalar(record,@"chatType","i");
    return [peer isKindOfClass:NSString.class]&&mid?[NSString stringWithFormat:@"%d:%@:%lld",chat,peer,mid]:nil;
}'''
assert s.count(anchor)==1,'identity=%d'%s.count(anchor)
FACTS='''static NSString *TKMessageIdentity(id record) {
    NSString *peer=TKObjectCall(record,@"peerUid");long long mid=TKScalar(record,@"msgId","q");
    int chat=(int)TKScalar(record,@"chatType","i");
    return [peer isKindOfClass:NSString.class]&&mid?[NSString stringWithFormat:@"%d:%@:%lld",chat,peer,mid]:nil;
}
/* 2.0.3: 撤回事实——onMsgRecall 通知一到达就把"哪个会话哪条序号被撤回了"记下来，
   完全不依赖消息内容缓存是否命中。显示时凭事实打标，退出重进/重启后从磁盘恢复。 */
static NSMutableSet *gTKRecallFacts=nil;
static NSString *TKRecallFactKey(int chat,NSString *peer,unsigned long long seq) {
    return (seq&&[peer isKindOfClass:NSString.class])?[NSString stringWithFormat:@"%d:%@:%llu",chat,peer,seq]:nil;
}
static NSString *TKRecallFactKeyOfRecord(id record) {
    NSString *peer=TKObjectCall(record,@"peerUid");unsigned long long seq=(unsigned long long)TKScalar(record,@"msgSeq","q");
    int chat=(int)TKScalar(record,@"chatType","i");
    return TKRecallFactKey(chat,peer,seq);
}
static NSString *TKRecallStorePath(void) {
    NSString *base=[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES) firstObject];
    if(!base)return nil;
    NSString *dir=[base stringByAppendingPathComponent:@"TIMCleanKit"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"recall-facts.json"];
}
static void TKRecallFactsLoad(void) {
    static BOOL loaded=NO;if(loaded)return;loaded=YES;
    @try {
        NSString *path=TKRecallStorePath();if(!path)return;
        NSData *d=[NSData dataWithContentsOfFile:path];if(!d)return;
        id obj=[NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        NSArray *facts=[obj isKindOfClass:NSDictionary.class]?obj[@"facts"]:([obj isKindOfClass:NSArray.class]?obj:nil);
        if(![facts isKindOfClass:NSArray.class]||!facts.count)return;
        [gTKCacheLock lock];
        if(!gTKRecallFacts)gTKRecallFacts=[NSMutableSet new];
        for(id f in facts)if([f isKindOfClass:NSString.class])[gTKRecallFacts addObject:f];
        [gTKCacheLock unlock];
    } @catch(NSException *ignored) {}
}
static void TKRecallFactsSaveAsync(void) {
    [gTKCacheLock lock];NSArray *snapshot=gTKRecallFacts.allObjects;[gTKCacheLock unlock];
    NSString *path=TKRecallStorePath();if(!path)return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND,0),^{
        @try {
            NSData *d=[NSJSONSerialization dataWithJSONObject:@{@"facts":snapshot,@"updated":@([[NSDate date] timeIntervalSince1970])} options:0 error:NULL];
            [d writeToFile:path atomically:YES];
        } @catch(NSException *ignored) {}
    });
}
static BOOL TKRecallFactsContains(NSString *fact) {
    if(!fact)return NO;
    [gTKCacheLock lock];BOOL r=[gTKRecallFacts containsObject:fact];[gTKCacheLock unlock];
    return r;
}
static void TKRecallFactAdd(NSString *fact) {
    if(!fact)return;
    [gTKCacheLock lock];
    if(!gTKRecallFacts)gTKRecallFacts=[NSMutableSet new];
    [gTKRecallFacts addObject:fact];
    if(gTKRecallFacts.count>10000)[gTKRecallFacts removeAllObjects];
    [gTKCacheLock unlock];
    TKRecallFactsSaveAsync();
}
static NSDictionary *TKRecallArchiveCache(void) {
    static NSDictionary *arch=nil;static BOOL loaded=NO;
    if(!loaded){loaded=YES;@try{
        NSString *path=TKRecallStorePath();if(path){
            path=[[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"recall-archive.json"];
            NSData *d=[NSData dataWithContentsOfFile:path];
            if(d)arch=[NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];}
    }@catch(NSException *ignored){}}
    return [arch isKindOfClass:NSDictionary.class]?arch:nil;
}'''
s=s.replace(anchor,FACTS)
print('1. fact 系统插入 OK')

# 2. TKWasRecalled 增强
old='''static BOOL TKWasRecalled(id record) {
    if([objc_getAssociatedObject(record,&kTKRecallFlag) boolValue])return YES;
    NSString *identity=TKMessageIdentity(record);if(!identity)return NO;
    [gTKCacheLock lock];BOOL recalled=[gTKRecalledIDs containsObject:identity];[gTKCacheLock unlock];
    return recalled;
}'''
assert s.count(old)==1,'wasRecalled=%d'%s.count(old)
NEW='''static BOOL TKWasRecalled(id record) {
    if(!record)return NO;
    if([objc_getAssociatedObject(record,&kTKRecallFlag) boolValue])return YES;
    NSString *identity=TKMessageIdentity(record);
    [gTKCacheLock lock];BOOL recalled=identity&&[gTKRecalledIDs containsObject:identity];[gTKCacheLock unlock];
    if(recalled)return YES;
    TKRecallFactsLoad();
    return TKRecallFactsContains(TKRecallFactKeyOfRecord(record));
}'''
s=s.replace(old,NEW)

# 3. TKMarkRecall 上限 2000→10000
old='if(gTKRecalledIDs.count>2000)[gTKRecalledIDs removeAllObjects];'
assert s.count(old)==1
s=s.replace(old,'if(gTKRecalledIDs.count>10000)[gTKRecalledIDs removeAllObjects];')

# 4. TKRememberMessage 删 recallTime>0 跳过
old='''    TKHookRecord *recallHook=TKRecord(@"OCMsgRecord",@selector(recallTime));
    IMP recall=TKOriginalIMP(recallHook);
    if(recall && ((long long(*)(id,SEL))recall)(record,@selector(recallTime))>0)return;
'''
assert s.count(old)==1,'recallSkip=%d'%s.count(old)
s=s.replace(old,'    /* 2.0.3: 不再按 recallTime>0 跳过——该字段不代表被撤回（TIM 正常流程也会写正数），跳过导致大量消息无法缓存、撤回时无内容可恢复 */\n')

# 5. 淘汰：500→1500 且不再删撤回标记
old='if(gTKRecentMessages.count>500){NSString *old=gTKRecentMessages.firstObject;[gTKRecentMessages removeObjectAtIndex:0];[gTKMessageCache removeObjectForKey:old];[gTKRecalledIDs removeObject:old];}'
assert s.count(old)==1
s=s.replace(old,'if(gTKRecentMessages.count>1500){NSString *old=gTKRecentMessages.firstObject;[gTKRecentMessages removeObjectAtIndex:0];[gTKMessageCache removeObjectForKey:old];} /* 2.0.3: 不在于此删撤回标记——标记的生命周期独立于消息缓存 */')

# 6. TKRestoreFromArchive：插在 TKRememberMessage 前
old='static void TKRememberMessage(id record) {'
assert s.count(old)==1
RESTORE='''/* 2.0.3: 无缓存快照但磁盘归档有文本——重建文本元素恢复内容（跨重启） */
static BOOL TKRestoreFromArchive(id record) {
    @try {
        NSDictionary *arch=TKRecallArchiveCache();if(!arch)return NO;
        NSString *identity=TKMessageIdentity(record);if(!identity)return NO;
        id item=arch[identity];
        if(![item isKindOfClass:NSDictionary.class])return NO;
        NSString *text=item[@"text"];
        if(![text isKindOfClass:NSString.class]||!text.length)return NO;
        Class elCls=NSClassFromString(@"OCMsgElement"),txCls=NSClassFromString(@"OCTextElement");
        if(!elCls||!txCls)return NO;
        id tx=[[txCls alloc] init],el=[[elCls alloc] init];
        SEL setContent=NSSelectorFromString(@"setContent:");
        SEL setType=NSSelectorFromString(@"setElementType:");
        SEL setTextEle=NSSelectorFromString(@"setTextElement:");
        if(!tx||!el||!TKMethodABI(tx,setContent,"v24@0:8@16")||!TKMethodABI(el,setType,"v20@0:8i16")||!TKMethodABI(el,setTextEle,"v24@0:8@16"))return NO;
        ((void(*)(id,SEL,id))objc_msgSend)(tx,setContent,[text copy]);
        ((void(*)(id,SEL,int))objc_msgSend)(el,setType,1);
        ((void(*)(id,SEL,id))objc_msgSend)(el,setTextEle,tx);
        IMP original=TKOriginalIMP(TKRecord(@"OCMsgRecord",@selector(setElements:)));
        if(!original)return NO;
        ((void(*)(id,SEL,id))original)(record,@selector(setElements:),@[el]);
        original=TKOriginalIMP(TKRecord(@"OCMsgRecord",@selector(setRecallTime:)));
        if(original)((void(*)(id,SEL,long long))original)(record,@selector(setRecallTime:),0);
        [gTKCacheLock lock];
        if(!gTKMessageCache)gTKMessageCache=[NSMutableDictionary new];
        if(!gTKRecentMessages)gTKRecentMessages=[NSMutableArray new];
        if(!gTKMessageCache[identity]){gTKMessageCache[identity]=@{@"record":record,@"elements":@[el],@"msgType":@((int)TKScalar(record,@"msgType","i"))};[gTKRecentMessages addObject:identity];}
        [gTKCacheLock unlock];
        __atomic_fetch_add(&gTKRecallRestores,1,__ATOMIC_RELAXED);
        TKRecallEvent([NSString stringWithFormat:@"归档恢复:%@",text.length>12?[text substringToIndex:12]:text]);
        return YES;
    } @catch(NSException *ignored) {}
    return NO;
}
static void TKRememberMessage(id record) {'''
s=s.replace(old,RESTORE)
print('2-6. Tweak.xm 主体 OK')

# 7. 版本 + warnings 文案
assert s.count('@"version":@"2.0.2"')==2,'ver=%d'%s.count('@"version":@"2.0.2"')
s=s.replace('@"version":@"2.0.2"','"version":@"2.0.3"'.join(['@','']))
old='防撤回：本次进程缓存最近500条收到/显示的消息；启动前丢失内容无法恢复。'
assert s.count(old)==1
s=s.replace(old,'防撤回：撤回检测为独立记录（退出重进/重启仍显示标记）；消息内容尽力恢复（进程缓存1500条 / 磁盘归档）。')
write(p,s)
print('7. 版本+warnings OK')

# 8. TKCellBridge.h：标签显示去掉"必须有缓存内容"
p=BASE+'/TKCellBridge.h'; s=read(p)
old='if(!TKAntiRecallEnabled()||!record||!TKWasRecalled(record)||!TKHasCachedContent(record)) {'
assert s.count(old)==1,'label=%d'%s.count(old)
s=s.replace(old,'if(!TKAntiRecallEnabled()||!record||!TKWasRecalled(record)) { /* 2.0.3: 确认撤回就一定显示——不再要求有缓存内容 */')
write(p,s)
print('8. 标签条件 OK')

# 9. TKMessageBridge.h：TKBridgeRecall 重写 + PreserveUpdateRecords else 分支
p=BASE+'/TKMessageBridge.h'; s=read(p)
old='''    if(TKAntiRecallEnabled()&&[peer isKindOfClass:NSString.class]&&seq) {
        [gTKCacheLock lock];NSArray *savedRecords=[gTKMessageCache.allValues copy];[gTKCacheLock unlock];
        for(NSDictionary *saved in savedRecords) {
            id record=saved[@"record"];
            if(TKScalar(record,@"chatType","i")==chat &&
               [TKObjectCall(record,@"peerUid") isEqual:peer] &&
               (unsigned long long)TKScalar(record,@"msgSeq","q")==seq && [saved[@"elements"] count]) {
                TKMarkRecall(record);TKRestoreRecord(record);blocked=YES;archivedRecord=record;
            }
        }
    }
    if(blocked){__atomic_fetch_add(&gTKRecallBlocked,1,__ATOMIC_RELAXED);if(archivedRecord)TKArchiveRecalledRecord(archivedRecord);TKRecallEvent([NSString stringWithFormat:@"onMsgRecall 标注:%@",archivedRecord?TKRecallTextOf(archivedRecord):@""]);TKRefreshRecallLabels();return;}'''
assert s.count(old)==1,'bridge=%d'%s.count(old)
NEW2='''    if(TKAntiRecallEnabled()&&[peer isKindOfClass:NSString.class]&&seq) {
        /* 2.0.3: 撤回事实独立记录——不依赖缓存是否命中（这正是"三条撤回只标出一条"的原因：通知到了但缓存找不到就不记） */
        TKRecallFactsLoad();
        NSString *fact=TKRecallFactKey(chat,peer,seq);
        TKRecallFactAdd(fact);
        TKRecallEvent([NSString stringWithFormat:@"onMsgRecall 记录:%@",fact]);
        [gTKCacheLock lock];NSArray *savedRecords=[gTKMessageCache.allValues copy];[gTKCacheLock unlock];
        for(NSDictionary *saved in savedRecords) {
            id record=saved[@"record"];
            /* 2.0.3: 放宽匹配——去掉 peerUid 硬条件（该字段在群/特殊会话不稳定），chatType+msgSeq 已唯一 */
            if(TKScalar(record,@"chatType","i")==chat && (unsigned long long)TKScalar(record,@"msgSeq","q")==seq && [saved[@"elements"] count]) {
                TKMarkRecall(record);TKRestoreRecord(record);blocked=YES;archivedRecord=record;
            }
        }
    }
    if(blocked){__atomic_fetch_add(&gTKRecallBlocked,1,__ATOMIC_RELAXED);if(archivedRecord)TKArchiveRecalledRecord(archivedRecord);TKRecallEvent([NSString stringWithFormat:@"onMsgRecall 标注:%@",archivedRecord?TKRecallTextOf(archivedRecord):@""]);}
    else if(TKAntiRecallEnabled()){TKRecallEvent(@"onMsgRecall 无缓存内容(事实已记,刷新后打标)");}
    if(TKAntiRecallEnabled())TKRefreshRecallLabels(); /* 2.0.3: 无条件刷新——没缓存内容的消息也凭撤回事实立刻打标 */
    if(blocked)return;'''
s=s.replace(old,NEW2)
old='''        // 2.0.2: 只有"已由撤回通知标记过"的消息才恢复；原 recallTime>0 条件在 TIM 上误报严重（正常消息也会被写正数）
        if(TKAntiRecallEnabled()&&TKWasRecalled(record)&&TKHasCachedContent(record)) {
            TKRestoreRecord(record);
            id old=TKCachedMessage(record)[@"record"];
            if(old){TKMarkRecall(old);TKRestoreRecord(old);[result addObject:old];}else [result addObject:record];
        } else {TKRememberMessage(record);[result addObject:record];}'''
assert s.count(old)==1,'preserve=%d'%s.count(old)
NEW3='''        // 2.0.3: 只要确认被撤回（事实记录/缓存标记）就处理——有快照恢复内容，无快照用归档重建；都没有也保留标记
        if(TKAntiRecallEnabled()&&TKWasRecalled(record)) {
            TKMarkRecall(record);
            if(TKHasCachedContent(record)) {
                TKRestoreRecord(record);
                id old=TKCachedMessage(record)[@"record"];
                if(old){TKMarkRecall(old);TKRestoreRecord(old);[result addObject:old];}else [result addObject:record];
            } else {
                TKRestoreFromArchive(record);
                [result addObject:record];
            }
        } else {TKRememberMessage(record);[result addObject:record];}'''
s=s.replace(old,NEW3)
write(p,s)
print('9. TKMessageBridge OK')

# 10. UI/control 版本
p=BASE+'/TKSettingsUI.h'; s=read(p)
s=s.replace('@"2.0.2 · 双指长按唤醒"','"2.0.3 · 双指长按唤醒"'.join(['@','']))
s=s.replace('?:@"2.0.2"','?:@"2.0.3"')
write(p,s)
p='/var/minis/shared/theos-ci/debs/TIMCleanKit/control'
s=read(p); s=s.replace('Version: 2.0.2','Version: 2.0.3'); write(p,s)
print('10. UI/control 版本 OK')
print('ALL PATCHES APPLIED (2.0.3)')
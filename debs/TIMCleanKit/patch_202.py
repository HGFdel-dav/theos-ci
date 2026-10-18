#!/usr/bin/env python3
# TIMCleanKit 2.0.2 补丁（包含 2.0.1 全部内容，用户未装 2.0.1 直接装这版）：
#  1) 撤回误报修复：setRecallTime(正数)≠被撤回（TIM 正常流程也写该字段）；
#     判定收紧为"只有收到撤回通知(onMsgRecall)且缓存有内容才标记/恢复/贴标签"
#  2) 新增撤回事件日志 recallLog（来源+原文前12字，环形12条）——下轮诊断可逐条定位
#  3) setRecallTime 正数观察计数 setRecallPositive
#  4) 版本 2.0.2
BASE = '/var/minis/shared/theos-ci/debs/TIMCleanKit/TIMCleanKit'

def read(p): return open(p, encoding='utf-8').read()
def write(p, s): open(p, 'w', encoding='utf-8').write(s)

p = BASE + '/Tweak.xm'; s = read(p)

# 1. 定义区：TKRecallEvent / TKRecallTextOf / gTKRecallLog / gTKSetRecallPos
old = 'static BOOL TKWasRecalled(id record);\n\nstatic BOOL TKAntiRecallEnabled(void) {'
assert s.count(old) == 1, 'def-anchor=%d' % s.count(old)
DEF = '''static BOOL TKWasRecalled(id record);

// 2.0.2: 撤回事件日志（环形12条，写入诊断 recallLog）——记录每次标记的来源和消息原文前12字，误报可逐条定位
static NSMutableArray *gTKRecallLog=nil;
static unsigned long long gTKSetRecallPos=0;
static void TKRecallEvent(NSString *s) {
    if(!s)return;
    NSString *line=[NSString stringWithFormat:@"%lldms %@",(long long)([[NSDate date] timeIntervalSince1970]*1000),s];
    [gTKCacheLock lock];
    if(!gTKRecallLog)gTKRecallLog=[NSMutableArray new];
    [gTKRecallLog addObject:line];
    while(gTKRecallLog.count>12)[gTKRecallLog removeObjectAtIndex:0];
    [gTKCacheLock unlock];
}
static NSString *TKRecallTextOf(id record) {
    NSString *r=@"";
    @try {
        id els=TK_performObject(record,@"elements");
        if([els isKindOfClass:NSArray.class]) {
            NSMutableString *t=[NSMutableString string];
            for(id e in els) {
                id te=TK_performObject(e,@"textElement"),c=te?TK_performObject(te,@"content"):nil;
                if([c isKindOfClass:NSString.class])[t appendString:c];
                if(t.length>=12)break;
            }
            if(t.length>12)[t deleteCharactersInRange:NSMakeRange(12,t.length-12)];
            r=t;
        }
    } @catch(NSException *ignored) {}
    return r;
}

static BOOL TKAntiRecallEnabled(void) {'''
s = s.replace(old, DEF)

# 2. AR_setRecallTime 重构
old = '''static void AR_setRecallTime(id self,SEL cmd,long long value) {
    IMP orig=OrigIMP(@"OCMsgRecord",cmd);
    if(value>0 && TKAntiRecallEnabled()) {
        TKMarkRecall(self);
        if(TKHasCachedContent(self))value=0;
    }
    if(orig)((void(*)(id,SEL,long long))orig)(self,cmd,value);
}'''
assert s.count(old) == 1, 'setRecall=%d' % s.count(old)
NEW = '''static void AR_setRecallTime(id self,SEL cmd,long long value) {
    IMP orig=OrigIMP(@"OCMsgRecord",cmd);
    if(value>0 && TKAntiRecallEnabled()) {
        // 2.0.2: setRecallTime(正数) ≠ 被撤回——TIM 正常流程也会写这个字段（真机误报实锤：9条标记仅3条来自撤回通知）。
        // 现在仅对"已由撤回通知标记过"的消息回写0重复拦截；未标记的只记录观察，不再产生标签。
        if(TKWasRecalled(self)) {
            TKRecallEvent([NSString stringWithFormat:@"setRecallTime=%lld(已标记,回写0) %@",value,TKRecallTextOf(self)]);
            if(TKHasCachedContent(self))value=0;
        } else if(gTKSetRecallPos<50) {
            gTKSetRecallPos++;
            TKRecallEvent([NSString stringWithFormat:@"setRecallTime=%lld(未标记,仅记录) %@",value,TKRecallTextOf(self)]);
        }
    }
    if(orig)((void(*)(id,SEL,long long))orig)(self,cmd,value);
}'''
s = s.replace(old, NEW)
print('1. AR_setRecallTime 收紧 OK')

# 3. 诊断 json 字段
old = '@"classProbe":gTKClassProbeCache,@"redEvents":(gTKRedEvents?[gTKRedEvents copy]:@[]),'
assert s.count(old) == 1
s = s.replace(old, '@"classProbe":gTKClassProbeCache,@"redEvents":(gTKRedEvents?[gTKRedEvents copy]:@[]),@"recallLog":(gTKRecallLog?[gTKRecallLog copy]:@[]),@"setRecallPositive":@(gTKSetRecallPos),')

# 4. 版本
assert s.count('@"version":@"2.0.1"') == 2, 'ver=%d' % s.count('@"version":@"2.0.1"')
s = s.replace('@"version":@"2.0.1"', '"version":@"2.0.2"'.join(['@', '']))
write(p, s)
print('2. 诊断字段+版本 OK')

# 5. TKMessageBridge.h：TKPreserveUpdateRecords 收紧 + TKBridgeRecall 加日志
p = BASE + '/TKMessageBridge.h'; s = read(p)
old = '''    NSMutableArray *result=[NSMutableArray arrayWithCapacity:[records count]];
    IMP originalRecall=TKOriginalIMP(TKRecord(@"OCMsgRecord",@selector(recallTime)));
    for(id record in records) {
        if(![record isKindOfClass:recordClass]){[result addObject:record];continue;}
        long long recall=originalRecall?((long long(*)(id,SEL))originalRecall)(record,@selector(recallTime)):0;
        if(TKAntiRecallEnabled()&&(recall>0||TKWasRecalled(record))&&TKHasCachedContent(record)) {
            TKMarkRecall(record);TKRestoreRecord(record);
            id old=TKCachedMessage(record)[@"record"];
            if(old){TKMarkRecall(old);TKRestoreRecord(old);[result addObject:old];}else [result addObject:record];
        } else {TKRememberMessage(record);[result addObject:record];}
    }
    return [result copy];'''
assert s.count(old) == 1, 'preserve=%d' % s.count(old)
NEW2 = '''    NSMutableArray *result=[NSMutableArray arrayWithCapacity:[records count]];
    for(id record in records) {
        if(![record isKindOfClass:recordClass]){[result addObject:record];continue;}
        // 2.0.2: 只有"已由撤回通知标记过"的消息才恢复；原 recallTime>0 条件在 TIM 上误报严重（正常消息也会被写正数）
        if(TKAntiRecallEnabled()&&TKWasRecalled(record)&&TKHasCachedContent(record)) {
            TKRestoreRecord(record);
            id old=TKCachedMessage(record)[@"record"];
            if(old){TKMarkRecall(old);TKRestoreRecord(old);[result addObject:old];}else [result addObject:record];
        } else {TKRememberMessage(record);[result addObject:record];}
    }
    return [result copy];'''
s = s.replace(old, NEW2)
old = 'if(blocked){__atomic_fetch_add(&gTKRecallBlocked,1,__ATOMIC_RELAXED);if(archivedRecord)TKArchiveRecalledRecord(archivedRecord);TKRefreshRecallLabels();return;}'
assert s.count(old) == 1, 'bridge=%d' % s.count(old)
s = s.replace(old, 'if(blocked){__atomic_fetch_add(&gTKRecallBlocked,1,__ATOMIC_RELAXED);if(archivedRecord)TKArchiveRecalledRecord(archivedRecord);TKRecallEvent([NSString stringWithFormat:@"onMsgRecall 标注:%@",archivedRecord?TKRecallTextOf(archivedRecord):@""]);TKRefreshRecallLabels();return;}')
write(p, s)
print('3. TKMessageBridge 收紧+日志 OK')

# 6. UI/control 版本
p = BASE + '/TKSettingsUI.h'; s = read(p)
s = s.replace('@"2.0.1 · 双指长按唤醒"', '"2.0.2 · 双指长按唤醒"'.join(['@', '']))
s = s.replace('?:@"2.0.1"', '?:@"2.0.2"')
write(p, s)
p = '/var/minis/shared/theos-ci/debs/TIMCleanKit/control'
s = read(p); s = s.replace('Version: 2.0.1', 'Version: 2.0.2'); write(p, s)
print('4. UI/control 版本 OK')
print('ALL PATCHES APPLIED')
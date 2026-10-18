#!/usr/bin/env python3
# TIMCleanKit 2.0.4：标签显示层修复（真机 2.0.3 日志确认撤回核心全对，错在"标签贴哪条"）
#  1) 误贴修正：标签若属于"另一条消息"，再判定时强制隐藏（原 1.0.22"不隐藏"把误贴固化了）
#  2) 复用残留帧修复：先归零隐藏、锚定成功后才显示（cell 复用时旧 frame/旧位置不再残留）
#  3) 标签决策日志 labelLog（最近8条：贴/隐+原因+文本前8字+可信度）——下轮可精确定位漏贴
#  4) 版本 2.0.4
BASE='/var/minis/shared/theos-ci/debs/TIMCleanKit/TIMCleanKit'
def read(p): return open(p,encoding='utf-8').read()
def write(p,s): open(p,'w',encoding='utf-8').write(s)

# ===== Tweak.xm =====
p=BASE+'/Tweak.xm'; s=read(p)
old='''static void TKRecallEvent(NSString *s) {
    if(!s)return;
    NSString *line=[NSString stringWithFormat:@"%lldms %@",(long long)([[NSDate date] timeIntervalSince1970]*1000),s];
    [gTKCacheLock lock];
    if(!gTKRecallLog)gTKRecallLog=[NSMutableArray new];
    [gTKRecallLog addObject:line];
    while(gTKRecallLog.count>12)[gTKRecallLog removeObjectAtIndex:0];
    [gTKCacheLock unlock];
}'''
assert s.count(old)==1,'event=%d'%s.count(old)
s=s.replace(old,old+'''
/* 2.0.4: 标签决策日志——记录每次"贴/隐"及其原因，用于精确排查"贴到哪条/哪条没贴" */
static NSMutableArray *gTKLabelLog=nil;
static unsigned long long gTKLabelShown=0,gTKLabelHidden=0;
static void TKLabelDiag(NSString *s) {
    if(!s)return;
    [gTKCacheLock lock];
    if(!gTKLabelLog)gTKLabelLog=[NSMutableArray new];
    [gTKLabelLog addObject:s];
    while(gTKLabelLog.count>8)[gTKLabelLog removeObjectAtIndex:0];
    [gTKCacheLock unlock];
}''')
old='@"recallLog":(gTKRecallLog?[gTKRecallLog copy]:@[]),@"setRecallPositive":@(gTKSetRecallPos),'
assert s.count(old)==1
s=s.replace(old,old+'@"labelLog":(gTKLabelLog?[gTKLabelLog copy]:@[]),@"labelShown":@(__atomic_load_n(&gTKLabelShown,__ATOMIC_RELAXED)),@"labelHidden":@(__atomic_load_n(&gTKLabelHidden,__ATOMIC_RELAXED)),')
assert s.count('@"version":@"2.0.3"')==2,'ver=%d'%s.count('@"version":@"2.0.3"')
s=s.replace('@"version":@"2.0.3"','"version":@"2.0.4"'.join(['@','']))
write(p,s)
print('1. Tweak.xm labelLog+版本 OK')

# ===== TKCellBridge.h =====
p=BASE+'/TKCellBridge.h'; s=read(p)
old='static char kTKBoundModelKey,kTKRecallLabelKey;'
assert s.count(old)==1
s=s.replace(old,'static char kTKBoundModelKey,kTKRecallLabelKey,kTKLabelRecordKey;')

old='''static void TKUpdateRecallLabel(UIView *cell) {
    if(!cell || !NSThread.isMainThread)return;
    id record=TKRecordForCell(cell);
    if(!record)record=TKCellRecord(cell);                  // 1.0.17: 布局时已文本匹配并关联
    if(!record)record=TKRecordMatchingTextInCache(cell);'''
assert s.count(old)==1,'label-head=%d'%s.count(old)
s=s.replace(old,'''static NSString *TKLabelBriefText(id record) {
    id els=TKObjectCall(record,@"elements");
    NSString *t=TKRecordTextOfElements([els isKindOfClass:NSArray.class]?els:@[]);
    if(!t.length)return @"?";
    return t.length>8?[t substringToIndex:8]:t;
}
static void TKUpdateRecallLabel(UIView *cell) {
    if(!cell || !NSThread.isMainThread)return;
    id record=TKRecordForCell(cell);
    BOOL highConfidence=(record!=nil);                     // 2.0.4: 从 cell→viewModel 直读=高可信
    if(!record)record=TKCellRecord(cell);                  // 1.0.17: 布局时已文本匹配并关联
    if(!record)record=TKRecordMatchingTextInCache(cell);''')

old='''    if(!TKAntiRecallEnabled()||!record||!TKWasRecalled(record)) { /* 2.0.3: 确认撤回就一定显示——不再要求有缓存内容 */
        if(label&&!label.hidden&&record)return;   // 1.0.22: 关联仍在时偶发判定失败不隐藏已显示的标签
        label.hidden=YES;return;
    }'''
assert s.count(old)==1,'label-cond=%d'%s.count(old)
s=s.replace(old,'''    if(!TKAntiRecallEnabled()||!record||!TKWasRecalled(record)) { /* 2.0.3: 确认撤回就一定显示——不再要求有缓存内容 */
        /* 2.0.4: 修误贴——标签若属于"另一条消息"（当前匹配 record 不同于标签记录的那条），必须隐藏；
           仅当仍是同一条消息（偶发判定波动）才保留不动。 */
        id labelRecord=label?objc_getAssociatedObject(label,&kTKLabelRecordKey):nil;
        if(label&&!label.hidden&&record&&labelRecord==record)return;
        if(label&&!label.hidden){__atomic_fetch_add(&gTKLabelHidden,1,__ATOMIC_RELAXED);TKLabelDiag([NSString stringWithFormat:@"隐:%@%@",record?TKLabelBriefText(record):@"无记录",highConfidence?@"(高可信)":@"(文本匹配)"]);}
        label.hidden=YES;if(label)label.frame=CGRectZero;return;
    }''')

old='''    label.hidden=NO;
    CGFloat width=70,height=18;'''
assert s.count(old)==1,'show=%d'%s.count(old)
s=s.replace(old,'''    label.hidden=YES;label.frame=CGRectZero;   /* 2.0.4: 先隐藏并归零，锚定成功后才显示——杜绝 cell 复用残留帧错位 */
    CGFloat width=70,height=18;''')

old='''    label.frame=CGRectMake(x,y,width,height);[cell bringSubviewToFront:label];
}'''
assert s.count(old)==1,'tail=%d'%s.count(old)
s=s.replace(old,'''    label.frame=CGRectMake(x,y,width,height);[cell bringSubviewToFront:label];
    label.hidden=NO;   /* 2.0.4: 锚定成功才显示 */
    objc_setAssociatedObject(label,&kTKLabelRecordKey,record,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __atomic_fetch_add(&gTKLabelShown,1,__ATOMIC_RELAXED);
    TKLabelDiag([NSString stringWithFormat:@"贴:%@%@",TKLabelBriefText(record),highConfidence?@"(高可信)":@"(文本匹配)"]);
}''')
write(p,s)
print('2. TKCellBridge 标签逻辑 OK')

# ===== UI/control 版本 =====
p=BASE+'/TKSettingsUI.h'; s=read(p)
s=s.replace('@"2.0.3 · 双指长按唤醒"','"2.0.4 · 双指长按唤醒"'.join(['@','']))
s=s.replace('?:@"2.0.3"','?:@"2.0.4"')
write(p,s)
p='/var/minis/shared/theos-ci/debs/TIMCleanKit/control'
s=read(p); s=s.replace('Version: 2.0.3','Version: 2.0.4'); write(p,s)
print('3. UI/control 版本 OK')
print('ALL PATCHES APPLIED (2.0.4)')
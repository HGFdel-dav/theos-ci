#!/usr/bin/env python3
# TIMCleanKit 2.0.5：实时刷新修复（用户实测：撤回后标签要退出聊天再进才出现）
#  1) TKRefreshRecallLabels 改为全窗口 UI 树扫描（原只刷登记过的 cell，翻旧消息/未走绑定钩子的 cell 刷不到）
#  2) setRecallTime 拦截"已标记"消息时立刻刷新（撤回处理当下就贴标）
#  3) labelLog 加时间戳；onMsgRecall 未命中时记录缓存 seq 样本（下轮定位匹配问题）
#  4) 版本 2.0.5
BASE='/var/minis/shared/theos-ci/debs/TIMCleanKit/TIMCleanKit'
def read(p): return open(p,encoding='utf-8').read()
def write(p,s): open(p,'w',encoding='utf-8').write(s)

p=BASE+'/Tweak.xm'; s=read(p)

# 1. labelLog 加时间戳
old='''static void TKLabelDiag(NSString *s) {
    if(!s)return;
    [gTKCacheLock lock];'''
assert s.count(old)==1,'diag=%d'%s.count(old)
s=s.replace(old,'''static void TKLabelDiag(NSString *s) {
    if(!s)return;
    s=[NSString stringWithFormat:@"%lldms %@",(long long)([[NSDate date] timeIntervalSince1970]*1000),s];
    [gTKCacheLock lock];''')

# 2. AR_setRecallTime 已标记分支：立刻刷新（撤回处理当下就贴标）
old='''        if(TKWasRecalled(self)) {
            TKRecallEvent([NSString stringWithFormat:@"setRecallTime=%lld(已标记,回写0) %@",value,TKRecallTextOf(self)]);
            if(TKHasCachedContent(self))value=0;
        } else if(gTKSetRecallPos<50) {'''
assert s.count(old)==1,'setrecall=%d'%s.count(old)
s=s.replace(old,'''        if(TKWasRecalled(self)) {
            TKRecallEvent([NSString stringWithFormat:@"setRecallTime=%lld(已标记,回写0) %@",value,TKRecallTextOf(self)]);
            if(TKHasCachedContent(self))value=0;
            TKRefreshRecallLabels(); /* 2.0.5: 撤回处理当下立刻刷新可见 cell——不等退出重进 */
        } else if(gTKSetRecallPos<50) {''')

# 3. 版本
assert s.count('@"version":@"2.0.4"')==2,'ver=%d'%s.count('@"version":@"2.0.4"')
s=s.replace('@"version":@"2.0.4"','"version":@"2.0.5"'.join(['@','']))
write(p,s)
print('1-3. Tweak.xm OK')

# 4. TKRefreshRecallLabels 全树扫描
p=BASE+'/TKCellBridge.h'; s=read(p)
old='''static void TKRefreshRecallLabels(void) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TKRefreshRecallLabels();});return;}
    for(UIView *cell in gTKVisibleCells.allObjects)TKUpdateRecallLabel(cell);
}'''
assert s.count(old)==1,'refresh=%d'%s.count(old)
s=s.replace(old,'''static void TKCollectMessageCells(UIView *root,NSMutableArray *out) {
    for(UIView *v in root.subviews) {
        NSString *cls=NSStringFromClass(v.class);
        if([cls containsString:@"Cell"]||[cls containsString:@"Bubble"])[out addObject:v];
        if(v.subviews.count)TKCollectMessageCells(v,out);
    }
}
static void TKRefreshRecallLabels(void) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TKRefreshRecallLabels();});return;}
    /* 2.0.5: 全窗口扫描——原只刷 gTKVisibleCells（登记不全/翻旧消息的 cell 不在里面），导致"要退出重进才显示标签" */
    NSMutableArray *cells=[NSMutableArray array];
    for(UIWindow *window in UIApplication.sharedApplication.windows) if(window.subviews.count)TKCollectMessageCells(window,cells);
    for(UIView *cell in cells)TKUpdateRecallLabel(cell);
    for(UIView *cell in gTKVisibleCells.allObjects)TKUpdateRecallLabel(cell);
}''')
write(p,s)
print('4. TKRefreshRecallLabels 全树 OK')

# 5. onMsgRecall 未命中日志加缓存 seq 样本
p=BASE+'/TKMessageBridge.h'; s=read(p)
old='''        [gTKCacheLock lock];NSArray *savedRecords=[gTKMessageCache.allValues copy];[gTKCacheLock unlock];
        for(NSDictionary *saved in savedRecords) {
            id record=saved[@"record"];
            /* 2.0.3: 放宽匹配——去掉 peerUid 硬条件（该字段在群/特殊会话不稳定），chatType+msgSeq 已唯一 */
            if(TKScalar(record,@"chatType","i")==chat && (unsigned long long)TKScalar(record,@"msgSeq","q")==seq && [saved[@"elements"] count]) {
                TKMarkRecall(record);TKRestoreRecord(record);blocked=YES;archivedRecord=record;
            }
        }
    }'''
assert s.count(old)==1,'loop=%d'%s.count(old)
s=s.replace(old,'''        [gTKCacheLock lock];NSArray *savedRecords=[gTKMessageCache.allValues copy];[gTKCacheLock unlock];
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
    }''')
write(p,s)
print('5. TKMessageBridge OK')

# 6. UI/control 版本
p=BASE+'/TKSettingsUI.h'; s=read(p)
s=s.replace('@"2.0.4 · 双指长按唤醒"','"2.0.5 · 双指长按唤醒"'.join(['@','']))
s=s.replace('?:@"2.0.4"','?:@"2.0.5"')
write(p,s)
p='/var/minis/shared/theos-ci/debs/TIMCleanKit/control'
s=read(p); s=s.replace('Version: 2.0.4','Version: 2.0.5'); write(p,s)
print('6. UI/control 版本 OK')
print('ALL PATCHES APPLIED (2.0.5)')
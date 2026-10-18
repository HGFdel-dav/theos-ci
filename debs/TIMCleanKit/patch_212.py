#!/usr/bin/env python3
# TIMCleanKit 2.2.1 = 2.2.0 + 修「撤回没生效」+「红包点了不领」
#
# 撤回（真机日志 2.2.0，21:31 一次撤回）：
#   6× setRecallTime≈now 拦截(不标记) → 3× onMsgRecall 标记 → 3× setRecallTime≈now 拦截(不标记)
#   即 TIM 先把 record 的 recallTime/elements/msgType 改掉，撤回通知(onMsgRecall)才到。
#   2.1.1 起「≈now 只拦截不打标」，而恢复钩子(AR_setElements/AR_setMsgType/AR_elements/AR_msgType)
#   全部以 TKWasRecalled 为闸门 → 标记到达前的清空/改类型全部放行 → 界面照样变成撤回提示。
#   修法：撤回瞬间打「临时保护标记」（只用于内容恢复，不产生标签，避免 2.1.1 的误标邻居），
#        就地快照原文；onMsgRecall 确认后把同一身份/同文本的临时标记提升为正式标记（此时才贴标签）。
#
# 红包（真机日志）：claimRequests=1、claimCallbacks=0、20s 超时；QQWalletPreGrapHBResultViewController.viewDidLoad 命中 1
#   → 点开预领页成功，但 TKAutoOpenPreView 只认类名 QQWalletPreOpenHBView（TIM 4.1.0 里没这个类）→ 没人点"开"。
#   修法：三次重试 + 不依赖类名的通用查找（UIButton/UIControl 标题含 开/拆/领，或类名含 open/grap），
#        并把预领页视图类名写进 redEvents 供下轮核对。
BASE='/var/minis/shared/theos-ci/debs/TIMCleanKit/TIMCleanKit'
def read(p): return open(p,encoding='utf-8').read()
def write(p,s): open(p,'w',encoding='utf-8').write(s)

p=BASE+'/Tweak.xm'; s=read(p)

# ---------------------------------------------------------------- 1. 前置声明
old='''static unsigned long long gTKRecallEvents,gTKRecallRestores;
static BOOL TKHasCachedContent(id record);
static void TKMarkRecall(id record);
static BOOL TKWasRecalled(id record);'''
assert s.count(old)==1,'fwd=%d'%s.count(old)
s=s.replace(old,'''static unsigned long long gTKRecallEvents,gTKRecallRestores;
static BOOL TKHasCachedContent(id record);
static void TKMarkRecall(id record);
static BOOL TKWasRecalled(id record);
/* 2.2.1: 撤回瞬间的临时保护标记（只管内容恢复，不产生标签） */
static char kTKRecallProvisional;
static NSMutableSet *gTKProvisionalIDs;
static NSMutableDictionary *gTKProvisionalInfo;
static unsigned long long gTKProvisionalMarks,gTKProvisionalHits;
static BOOL TKIsProvisional(id record);
static void TKMarkProvisional(id record);
static BOOL TKShouldProtect(id record);
static void TKSnapshotNow(id record);
static void TKPromoteProvisional(id record);
static long long TKScalar(id obj,NSString *method,const char *encoding); /* 2.2.1: 前向声明（定义在下方） */''')

# ---------------------------------------------------------------- 2. AR_setRecallTime：临时保护 + 就地快照
old='''            /* 2.1.1: 只拦截、不打标——TIM 会给多条消息批量写同一时间戳，
               按字段打标会误标未撤回的邻居（真机："第三句"未撤回却带标签）。
               标签统一由 onMsgRecall（撤回通知）的 seq 匹配产生。 */
            TKRecallEvent([NSString stringWithFormat:@"setRecallTime≈now 拦截(不标记):%@",TKRecallTextOf(self)]);
            value=0; /* 确认撤回就拦截——无条件回写0，内容不删 */
            TKRefreshRecallLabels();'''
assert s.count(old)==1,'setrt=%d'%s.count(old)
s=s.replace(old,'''            /* 2.2.1: 这里才是「撤回真正发生」的瞬间——TIM 先写 recallTime，再清 elements / 改 msgType，
               撤回通知(onMsgRecall)通常最后才到（真机日志：6×≈now → 3×onMsgRecall → 3×≈now）。
               2.1.1 只拦截不打标，导致通知到达前的清空全部放行、界面照样变撤回提示。
               现在：就地快照原文 + 打临时保护标记（内容恢复用），标签仍只由 onMsgRecall 确认后产生。 */
            TKSnapshotNow(self);
            TKMarkProvisional(self);
            TKRecallEvent([NSString stringWithFormat:@"setRecallTime≈now 保护(seq=%lld msgId=%lld):%@",TKScalar(self,@"msgSeq","q"),TKScalar(self,@"msgId","q"),TKRecallTextOf(self)]);
            value=0; /* 确认撤回就拦截——无条件回写0，内容不删 */
            TKRefreshRecallLabels();''')

# ---------------------------------------------------------------- 3. 恢复闸门：确认标记 或 临时保护
for old,new in [
 ('    return TKAntiRecallEnabled() && TKWasRecalled(self) && TKHasCachedContent(self)?0:value;',
  '    return TKShouldProtect(self) && TKHasCachedContent(self)?0:value;'),
 ('    if(TKAntiRecallEnabled()&&TKWasRecalled(self)) {\n        NSArray *saved=TKCachedMessage(self)[@"elements"];if(saved.count){elements=saved;',
  '    if(TKShouldProtect(self)) {\n        NSArray *saved=TKCachedMessage(self)[@"elements"];if(saved.count){elements=saved;'),
 ('    if(TKAntiRecallEnabled()&&TKWasRecalled(self)) {\n        NSArray *saved=TKCachedMessage(self)[@"elements"];if(saved.count)return saved;',
  '    if(TKShouldProtect(self)) {\n        NSArray *saved=TKCachedMessage(self)[@"elements"];if(saved.count)return saved;'),
 ('    if(TKAntiRecallEnabled()&&TKWasRecalled(self)) {\n        NSNumber *saved=TKCachedMessage(self)[@"msgType"];if(saved)return saved.intValue;',
  '    if(TKShouldProtect(self)) {\n        NSNumber *saved=TKCachedMessage(self)[@"msgType"];if(saved)return saved.intValue;'),
 ('    if(TKAntiRecallEnabled()&&TKWasRecalled(self)) {\n        NSNumber *saved=TKCachedMessage(self)[@"msgType"];if(saved)value=saved.intValue;',
  '    if(TKShouldProtect(self)) {\n        NSNumber *saved=TKCachedMessage(self)[@"msgType"];if(saved)value=saved.intValue;'),
]:
    assert s.count(old)==1,'gate=%d %s'%(s.count(old),old[:48])
    s=s.replace(old,new)

# ---------------------------------------------------------------- 4. TKMarkRecall 末尾提升临时标记
old='''    for(NSString *k in keys)[gTKRecalledIDs addObject:k]; /* 2.0.9: 双键都记，UI 用哪个都能命中 */
    if(gTKRecalledIDs.count>10000)[gTKRecalledIDs removeAllObjects];
    [gTKCacheLock unlock];
}'''
s=s.replace('    NSArray *keys=TKMessageIdentityKeys(record);if(!keys.count)return;','    NSArray *keys=TKMessageIdentityKeys(record);if(!keys.count){TKPromoteProvisional(record);return;}',1)
assert s.count(old)==1,'mark=%d'%s.count(old)
s=s.replace(old,'''    for(NSString *k in keys)[gTKRecalledIDs addObject:k]; /* 2.0.9: 双键都记，UI 用哪个都能命中 */
    if(gTKRecalledIDs.count>10000)[gTKRecalledIDs removeAllObjects];
    [gTKCacheLock unlock];
    TKPromoteProvisional(record); /* 2.2.1: 同一身份/同文本的临时保护提升为正式标记（此后才贴标签） */
}''')

# ---------------------------------------------------------------- 5. 临时保护实现（放在 TKMarkRecall 之后）
anchor='''/* 2.0.3: 无缓存快照但磁盘归档有文本——重建文本元素恢复内容（跨重启） */'''
assert s.count(anchor)==1,'anchor=%d'%s.count(anchor)
s=s.replace(anchor,'''/* ---------- 2.2.1: 临时保护标记（撤回瞬间就打，只用于内容恢复） ---------- */
static void TKMarkProvisional(id record) {
    if(!record)return;
    objc_setAssociatedObject(record,&kTKRecallProvisional,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __atomic_fetch_add(&gTKProvisionalMarks,1,__ATOMIC_RELAXED);
    NSArray *keys=TKMessageIdentityKeys(record);if(!keys.count)return;
    NSString *peer=TKObjectCall(record,@"peerUid"),*text=TKRecallTextOf(record);
    [gTKCacheLock lock];
    if(!gTKProvisionalIDs)gTKProvisionalIDs=[NSMutableSet new];
    if(!gTKProvisionalInfo)gTKProvisionalInfo=[NSMutableDictionary new];
    for(NSString *k in keys){
        [gTKProvisionalIDs addObject:k];
        gTKProvisionalInfo[k]=@{@"peer":peer?:@"",@"text":text?:@""};
    }
    if(gTKProvisionalIDs.count>4000){[gTKProvisionalIDs removeAllObjects];[gTKProvisionalInfo removeAllObjects];}
    [gTKCacheLock unlock];
}
static BOOL TKIsProvisional(id record) {
    if(!record)return NO;
    if([objc_getAssociatedObject(record,&kTKRecallProvisional) boolValue])return YES;
    NSArray *keys=TKMessageIdentityKeys(record);if(!keys.count)return NO;
    [gTKCacheLock lock];BOOL hit=NO;for(NSString *k in keys){if([gTKProvisionalIDs containsObject:k]){hit=YES;break;}}[gTKCacheLock unlock];
    if(hit)__atomic_fetch_add(&gTKProvisionalHits,1,__ATOMIC_RELAXED);
    return hit;
}
static BOOL TKShouldProtect(id record){return TKAntiRecallEnabled()&&(TKWasRecalled(record)||TKIsProvisional(record));}
/* 撤回瞬间 elements 还在（真机日志实锤），就地快照，不依赖收消息时的缓存 */
static void TKSnapshotNow(id record) {
    if(!record)return;
    NSString *identity=TKMessageIdentity(record);if(!identity)return;
    id elements=TKObjectCall(record,@"elements");
    if(![elements isKindOfClass:NSArray.class]||[(NSArray *)elements count]==0)return;
    NSMutableArray *snapshot=[NSMutableArray new];
    for(id element in elements){
        id copy=[element conformsToProtocol:@protocol(NSCopying)]?[element copy]:element;
        if(copy)[snapshot addObject:copy];
    }
    if(!snapshot.count)return;
    int type=(int)TKScalar(record,@"msgType","i");
    [gTKCacheLock lock];
    if(!gTKMessageCache)gTKMessageCache=[NSMutableDictionary new];
    if(!gTKRecentMessages)gTKRecentMessages=[NSMutableArray new];
    BOOL added=NO;
    if(!gTKMessageCache[identity]){gTKMessageCache[identity]=@{@"record":record,@"elements":[snapshot copy],@"msgType":@(type)};[gTKRecentMessages addObject:identity];added=YES;}
    [gTKCacheLock unlock];
    TKArchiveRecalledRecord(record); /* 2.2.1: 撤回瞬间归档原文，重启后仍可恢复 */
    if(added)TKRecallEvent([NSString stringWithFormat:@"撤回前快照:%@",TKRecallTextOf(record)]);
}
/* onMsgRecall 确认后，把同一身份（或同会话同文本）的临时标记提升为正式标记 —— 标签此刻才出现 */
static void TKPromoteProvisional(id record) {
    NSArray *keys=TKMessageIdentityKeys(record);
    NSString *peer=TKObjectCall(record,@"peerUid"),*text=TKRecallTextOf(record);
    [gTKCacheLock lock];
    if(!gTKProvisionalInfo.count){[gTKCacheLock unlock];return;}
    NSMutableArray *promote=[NSMutableArray array];
    for(NSString *k in keys)if(gTKProvisionalInfo[k])[promote addObject:k];
    for(NSString *k in gTKProvisionalInfo){
        if([promote containsObject:k])continue;
        NSDictionary *info=gTKProvisionalInfo[k];
        if(text.length&&[info[@"text"] isEqual:text]&&(!peer.length||[info[@"peer"] isEqual:peer]))[promote addObject:k];
    }
    if(promote.count){
        if(!gTKRecalledIDs)gTKRecalledIDs=[NSMutableSet new];
        for(NSString *k in promote){[gTKRecalledIDs addObject:k];[gTKProvisionalIDs removeObject:k];}
    }
    [gTKCacheLock unlock];
    if(promote.count)TKRecallEvent([NSString stringWithFormat:@"临时保护提升为确认标记 %lu 条",(unsigned long)promote.count]);
}

/* 2.0.3: 无缓存快照但磁盘归档有文本——重建文本元素恢复内容（跨重启） */''')

# ---------------------------------------------------------------- 6. 诊断字段
old='@"recallEvents":@(__atomic_load_n(&gTKRecallEvents,__ATOMIC_RELAXED)),'
assert s.count(old)==1,'diag1=%d'%s.count(old)
s=s.replace(old,old+'@"provisionalMarks":@(__atomic_load_n(&gTKProvisionalMarks,__ATOMIC_RELAXED)),@"provisionalHits":@(__atomic_load_n(&gTKProvisionalHits,__ATOMIC_RELAXED)),@"preOpenTaps":@(__atomic_load_n(&gTKPreOpenTaps,__ATOMIC_RELAXED)),@"preOpenProbe":(gTKPreOpenProbe?:@""),')
write(p,s)
print('1-6. Tweak.xm 撤回侧 OK')

# ---------------------------------------------------------------- 7. 红包：通用查找 + 三次重试
old='''static void TKAutoOpenPreView(id self,SEL cmd) {
    IMP orig=OrigIMP(@"QQWalletPreGrapHBResultViewController",cmd);
    if(orig)((void(*)(id,SEL))orig)(self,cmd);
    if(!gTKAutoBusy)return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if(!gTKAutoBusy||!prefBool(kAutoRed,YES))return;
        UIView *root=(UIView *)TKObjectCall(self,@"view");
        NSMutableArray *views=[NSMutableArray array];if(root)[views addObject:root];
        for(NSUInteger i=0;i<views.count&&i<1000;i++){
            UIView *view=views[i];
            if([view isKindOfClass:NSClassFromString(@"QQWalletPreOpenHBView")]) {
                id data=TKObjectCall(view,@"grapHBData");
                id aio=TKObjectCall(data,@"aioData");id list=TKObjectCall(aio,@"listId");
                BOOL identityOK=!gTKCurrentClaimIdentity||!list||[list isEqual:gTKCurrentClaimIdentity];
                if(identityOK){SEL open=NSSelectorFromString(@"openButtonClick");if([view respondsToSelector:open])((void(*)(id,SEL))objc_msgSend)(view,open);}
                return;
            }
            if([view isKindOfClass:UIView.class])[views addObjectsFromArray:view.subviews];
        }
    });
}'''
assert s.count(old)==1,'preopen=%d'%s.count(old)
new='''static NSString *TKControlTitleText(UIView *v) {
    @try {
        if([v isKindOfClass:UIButton.class]) {
            UIButton *b=(UIButton *)v;
            NSString *t=[b titleForState:UIControlStateNormal];
            if(!t.length)t=b.titleLabel.text;
            return t;
        }
        if([v isKindOfClass:UILabel.class])return ((UILabel *)v).text;
    } @catch(NSException *ignored) {}
    return nil;
}
static BOOL TKTitleLooksLikeOpen(NSString *t) {
    if(!t.length||t.length>6)return NO;
    if([t containsString:@"关闭"]||[t containsString:@"取消"])return NO;
    return [t containsString:@"开"]||[t containsString:@"拆"]||[t containsString:@"领"];
}
/* 2.2.1: 不再依赖 QQWalletPreOpenHBView（TIM 4.1.0 没这个类，classProbe 已证实）——
   按「类名含 open/grap」或「标题含 开/拆/领」找可点控件，并把视图类名回写诊断。 */
static BOOL TKTryOpenPreGrapView(UIView *root,NSMutableString *probe) {
    if(!root)return NO;
    NSMutableArray *queue=[NSMutableArray arrayWithObject:root];
    NSUInteger scanned=0;
    while(queue.count&&scanned<800){
        UIView *v=queue.firstObject;[queue removeObjectAtIndex:0];scanned++;
        NSString *cls=NSStringFromClass(v.class);
        if(probe&&cls.length&&probe.length<380&&![probe containsString:cls])[probe appendFormat:@"%@ ",cls];
        SEL open=NSSelectorFromString(@"openButtonClick");
        if([v respondsToSelector:open]) {
            id data=TKObjectCall(v,@"grapHBData");
            id aio=TKObjectCall(data,@"aioData");id list=TKObjectCall(aio,@"listId");
            BOOL identityOK=!gTKCurrentClaimIdentity||!list||[list isEqual:gTKCurrentClaimIdentity];
            if(identityOK){((void(*)(id,SEL))objc_msgSend)(v,open);return YES;}
        }
        if([v isKindOfClass:UIControl.class]) {
            UIControl *c=(UIControl *)v;
            if(!c.hidden&&c.alpha>0.01&&c.userInteractionEnabled) {
                NSString *title=TKControlTitleText(v);
                NSString *lower=cls.lowercaseString;
                BOOL nameHit=[lower containsString:@"open"]||[lower containsString:@"grap"]||[lower containsString:@"hongbao"];
                if(TKTitleLooksLikeOpen(title)||(nameHit&&!title.length)) {
                    [c sendActionsForControlEvents:UIControlEventTouchUpInside];
                    return YES;
                }
            }
        }
        if(v.subviews.count)[queue addObjectsFromArray:v.subviews];
    }
    return NO;
}
static void TKAutoOpenPreView(id self,SEL cmd) {
    IMP orig=OrigIMP(@"QQWalletPreGrapHBResultViewController",cmd);
    if(orig)((void(*)(id,SEL))orig)(self,cmd);
    if(!gTKAutoBusy)return;
    for(int attempt=0;attempt<3;attempt++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(350+attempt*700)*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            if(!gTKAutoBusy||!prefBool(kAutoRed,YES))return;
            UIView *root=(UIView *)TKObjectCall(self,@"view");
            NSMutableString *probe=[NSMutableString string];
            BOOL tapped=TKTryOpenPreGrapView(root,probe);
            if(probe.length)gTKPreOpenProbe=[probe copy];
            if(tapped){__atomic_fetch_add(&gTKPreOpenTaps,1,__ATOMIC_RELAXED);TKRedEvent([NSString stringWithFormat:@"预领页已点击开红包按钮(第%d次尝试)",attempt+1]);}
            else if(attempt==2)TKRedEvent([NSString stringWithFormat:@"预领页未找到开红包按钮:%@",probe.length?probe:@"空视图"]);
        });
    }
}'''
s=s.replace(old,new)

# 超时文案：区分「已经点过开」
old='''        if(gTKAutoBusy && generation==gTKAutoGeneration){gTKAutoBusy=NO;gTKAutoErrors++;gTKEngineStatus=@"领取超时：未收到完成回调";TKDrainRedQueue();}'''
assert s.count(old)==1,'timeout=%d'%s.count(old)
s=s.replace(old,'''        if(gTKAutoBusy && generation==gTKAutoGeneration){gTKAutoBusy=NO;gTKAutoErrors++;
            gTKEngineStatus=gTKPreOpenTaps>tapsAtStart?@"已点击开红包，未收到完成回调（以界面为准）":@"领取超时：未收到完成回调";
            TKDrainRedQueue();}''')
old='''    gTKAutoBusy=YES;unsigned long long generation=++gTKAutoGeneration;gTKAutoAttempts++;'''
assert s.count(old)==1,'gen=%d'%s.count(old)
s=s.replace(old,'''    gTKAutoBusy=YES;unsigned long long generation=++gTKAutoGeneration;gTKAutoAttempts++;
    unsigned long long tapsAtStart=__atomic_load_n(&gTKPreOpenTaps,__ATOMIC_RELAXED);''')
# 全局变量必须声明在使用之前（TKDrainRedQueue 在红包段之前）
old='''static unsigned long long gTKGestureTaps,gTKGestureNoRecord;'''
assert s.count(old)==1,'globals=%d'%s.count(old)
s=s.replace(old,'''static unsigned long long gTKGestureTaps,gTKGestureNoRecord;
static unsigned long long gTKPreOpenTaps=0; /* 2.2.1: 预领页点击次数（诊断/超时判定） */
static NSString *gTKPreOpenProbe=nil;       /* 2.2.1: 预领页视图类名探针 */''')
write(p,s)
print('7. Tweak.xm 红包侧 OK')

# ---------------------------------------------------------------- 8. TKMessageBridge.h 保护面扩大
p4=BASE+'/TKMessageBridge.h'; m=read(p4)
old='''        if(TKAntiRecallEnabled()&&TKWasRecalled(record)) {'''
assert m.count(old)==1,'bridge=%d'%m.count(old)
m=m.replace(old,'''        // 2.2.1: 临时保护（setRecallTime≈now）也走这条，否则列表更新会把内容换成撤回提示
        if(TKAntiRecallEnabled()&&TKShouldProtect(record)) {''')
old='''BOOL recalled=[gTKRecalledIDs containsObject:identity];'''
assert m.count(old)==1,'delete=%d'%m.count(old)
m=m.replace(old,'''BOOL recalled=[gTKRecalledIDs containsObject:identity]||[gTKProvisionalIDs containsObject:identity];''')
write(p4,m)
print('8. TKMessageBridge.h OK')

# ---------------------------------------------------------------- 9. 版本
s=read(p)
assert s.count('@"version":@"2.2.0"')==2,'ver=%d'%s.count('@"version":@"2.2.0"')
s=s.replace('@"version":@"2.2.0"','@"version":@"2.2.1"')
write(p,s)
p2=BASE+'/TKSettingsUI.h'; t=read(p2)
t=t.replace('@"2.2.0 · 双指长按唤醒"','@"2.2.1 · 双指长按唤醒"').replace('?:@"2.2.0"','?:@"2.2.1"')
write(p2,t)
p3='/var/minis/shared/theos-ci/debs/TIMCleanKit/control'; c=read(p3)
c=c.replace('Version: 2.2.0','Version: 2.2.1'); write(p3,c)
print('8. 版本 2.2.1 OK')
print('ALL PATCHES APPLIED (2.2.1)')

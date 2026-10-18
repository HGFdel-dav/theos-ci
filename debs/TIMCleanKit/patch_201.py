#!/usr/bin/env python3
# TIMCleanKit 2.0.1 补丁：
#  1) 复读：双击手势直接挂到每个消息 cell（窗口级手势被聊天列表吃掉 → gestureTaps=0）
#  2) 红包：全链路事件记录 redEvents（进入诊断）——"红包到没到/为什么跳过/有没有领取"一目了然
#  3) 探针提前：任何红包（含将被跳过的）都 dump 字段到 redProbe
#  4) 版本 2.0.1
BASE = '/var/minis/shared/theos-ci/debs/TIMCleanKit/TIMCleanKit'

def read(p): return open(p, encoding='utf-8').read()
def write(p, s): open(p, 'w', encoding='utf-8').write(s)

def extract_func(src, signature):
    i = src.find(signature)
    assert i >= 0, 'signature not found: ' + signature
    j = src.find('{', i); assert j >= 0
    depth = 0; k = j
    while k < len(src):
        c = src[k]
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return i, k + 1
        k += 1
    raise AssertionError('unbalanced: ' + signature)

# ================= 1. TKCellBridge.h：cell 级双击手势 =================
p = BASE + '/TKCellBridge.h'; s = read(p)
old = 'static BOOL TKCellBind(id self,SEL cmd,id vm) {'
assert s.count(old) == 1
FUNC = '''// 2.0.1: 保证双击复读手势能被收到——窗口级手势会被聊天列表/气泡控件吃掉（真机 gestureTaps=0），
// 改为直接挂到每个消息 cell 上（cancelsTouchesInView=NO 不影响原有点击）。
static void TKEnsureCellGesture(UIView *cell) {
    if(!cell)return;
    static char kTKGestureCell;
    if(objc_getAssociatedObject(cell,&kTKGestureCell))return;
    Class targetClass=NSClassFromString(@"TIMCKGestureTarget");
    if(!targetClass)return;
    id target=nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    target=[targetClass performSelector:NSSelectorFromString(@"shared")];
#pragma clang diagnostic pop
    if(!target)return;
    UITapGestureRecognizer *g=[[UITapGestureRecognizer alloc] initWithTarget:target action:NSSelectorFromString(@"onMessageDoubleTap:")];
    g.numberOfTapsRequired=2;g.numberOfTouchesRequired=1;g.cancelsTouchesInView=NO;g.delaysTouchesBegan=NO;g.delaysTouchesEnded=NO;
    g.delegate=target;
    [cell addGestureRecognizer:g];
    objc_setAssociatedObject(cell,&kTKGestureCell,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
'''
s = s.replace(old, FUNC + old)
# Bind 里调用
old1 = '''        id record=TKRecordForCell(self);if(record)TKRememberMessage(record);else gTKRecordReadFailures++;
        TKUpdateRecallLabel(self);
    }
    return accepted;'''
assert s.count(old1) == 1, 'bind1=%d' % s.count(old1)
s = s.replace(old1, old1.replace('    }\n    return accepted;', '        TKEnsureCellGesture((UIView*)self);\n    }\n    return accepted;'))
# BindVM 里调用
old2 = '''objc_setAssociatedObject(self,&kTKBoundModelKey,vm,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gTKMessageBinds++;if(!gTKVisibleCells)gTKVisibleCells=[NSHashTable weakObjectsHashTable];[gTKVisibleCells addObject:self];
        id record=TKRecordForCell(self);if(record)TKRememberMessage(record);else gTKRecordReadFailures++;
        TKUpdateRecallLabel(self);
    }
}'''
assert s.count(old2) == 1, 'bind2=%d' % s.count(old2)
s = s.replace(old2, old2.replace('        TKUpdateRecallLabel(self);\n    }\n}', '        TKUpdateRecallLabel(self);\n        TKEnsureCellGesture((UIView*)self);\n    }\n}'))
write(p, s)
print('1. cell 级手势 OK')

# ================= 2. Tweak.xm =================
p = BASE + '/Tweak.xm'; s = read(p)

# 2a. TKRedEvent 定义（插在 TKProbeRedPacket 前）
old = 'static void TKProbeRedPacket(id record) {'
assert s.count(old) == 1
DEF = '''// 2.0.1: 红包处理全链路事件记录（环形最近12条，写入诊断 json 的 redEvents 字段）
static NSMutableArray *gTKRedEvents=nil;
static void TKRedEvent(NSString *s) {
    if(!s)return;
    if(!gTKRedEvents)gTKRedEvents=[NSMutableArray new];
    [gTKRedEvents addObject:[NSString stringWithFormat:@"%lldms %@",(long long)([[NSDate date] timeIntervalSince1970]*1000),s]];
    while(gTKRedEvents.count>12)[gTKRedEvents removeObjectAtIndex:0];
}
'''
s = s.replace(old, DEF + old)

# 2b. TKQueueRedPacket 全函数替换
sig = 'static void TKQueueRedPacket(id record) {'
a, b = extract_func(s, sig)
NEWQ = '''static void TKQueueRedPacket(id record) {
    id wallet0=redElementFromRecord(record);
    if(!wallet0)return; // 非红包消息：静默
    long long redType0=TKIntCall(wallet0,@"redType");
    long long amount0=redPacketTotalAmount(wallet0);
    TKRedEvent([NSString stringWithFormat:@"红包到达 redType=%lld amount=%lld分",redType0,amount0]);
    if(!prefBool(kEnabled,YES)||!prefBool(kRedPacket,YES)||!prefBool(kAutoRed,YES)){TKRedEvent(@"跳过:功能或自动领取开关未开启");return;}
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive){
        // 1.0.23: 红包到达瞬间可能刚切回前台、系统状态尚未刷新——0.4s 后重试一次再放弃
        static char TKRedRetryKey;
        if(!objc_getAssociatedObject(record,&TKRedRetryKey)) {
            objc_setAssociatedObject(record,&TKRedRetryKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,400*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
                objc_setAssociatedObject(record,&TKRedRetryKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                TKQueueRedPacket(record);   // ARC: block 已自动强引用 record
            });
            gTKEngineStatus=@"应用未在前台，已安排0.4s后重试";
        } else {gTKEngineStatus=@"应用未在前台，未请求领取";TKRedEvent(@"跳过:应用非前台(重试后仍未激活)");}
        return;
    }
    id wallet=wallet0;if(!wallet||shouldSkipRedPacket(record)){TKRedEvent(@"跳过:命中过滤规则(见上一条)");return;}
    long long time=TKScalar(record,@"msgTime","q");NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    if(time>100000000000LL)time/=1000;
    if(time<=0||now-time>120||time>now+30){TKRedEvent([NSString stringWithFormat:@"跳过:消息时间窗外(%lld)",time]);return;} // Never claim old synchronized history.
    NSString *identity=TKMessageIdentity(record);if(!identity)return;
    NSString *bill=TKObjectCall(wallet,@"billNo");NSString *key=[bill isKindOfClass:NSString.class]&&bill.length?bill:identity;
    if(!gTKSeenRedPackets)gTKSeenRedPackets=[NSMutableSet new];
    if([gTKSeenRedPackets containsObject:key]){TKRedEvent(@"跳过:重复红包(已处理过)");return;}
    if(gTKSeenRedPackets.count>=500){gTKEngineStatus=@"本次会话已达去重上限，请关闭再开启自动领取";return;}
    [gTKSeenRedPackets addObject:key];
    if(!gTKRedQueue)gTKRedQueue=[NSMutableArray new];
    if(gTKRedQueue.count<20)[gTKRedQueue addObject:record];
    TKRedEvent(@"已入队,等待领取");
    TKDrainRedQueue();
}'''
s = s[:a] + NEWQ + s[b:]
print('2. TKQueueRedPacket 重构 OK')

# 2c. 探针提前：element 判定后立即 dump；删掉原调用
old = '''    if (!element) return NO;

    // 测试红包'''
assert s.count(old) == 1
s = s.replace(old, '''    if (!element) return NO;
    TKProbeRedPacket(record);   // 2.0.1: 探针提前——任何红包（含将被跳过的）都留档字段

    // 测试红包''')
old = '    gTKLastRedAmount=amount; gTKLastRedType=redType;\n    TKProbeRedPacket(record);\n'
assert s.count(old) == 1, 'probe-old=%d' % s.count(old)
s = s.replace(old, '    gTKLastRedAmount=amount; gTKLastRedType=redType;\n')

# 2d. shouldSkip 事件记录
old = '        LOG(@"skip test red packet"); return YES;'
assert s.count(old) == 1
s = s.replace(old, '        LOG(@"skip test red packet"); TKRedEvent(@"跳过:命中测试红包关键词"); return YES;')
old = 'if (isCmd) { LOG(@"skip command red packet"); return YES; }'
assert s.count(old) == 1
s = s.replace(old, 'if (isCmd) { LOG(@"skip command red packet"); TKRedEvent(@"跳过:口令红包"); return YES; }')
old = '    if(min>0 && amount>=0 && amount<min){gTKSkipUnknownAmount++;return YES;}'
assert s.count(old) == 1
s = s.replace(old, '    if(min>0 && amount>=0 && amount<min){gTKSkipUnknownAmount++;TKRedEvent([NSString stringWithFormat:@"跳过:金额%lld分低于起抢线%lld分",amount,min]);return YES;}')
old = '''        if(!prefBool(kRedAllowUnknown,YES)){gTKSkipCommonType++;return YES;}
    }'''
assert s.count(old) == 1, 'skipcommon=%d' % s.count(old)
s = s.replace(old, '''        if(!prefBool(kRedAllowUnknown,YES)){gTKSkipCommonType++;TKRedEvent(@"跳过:普通红包-金额未知且放行开关关闭");return YES;}
        else TKRedEvent(@"放行:普通红包-金额未知,按放行开关设置继续领取");
    }''')

# 2e. TKDrainRedQueue 领取处记录
old = '    gTKEngineStatus=hasRouter?@"已调用TIM原生红包路由（模拟点击），等待完成回调":@"已调用兼容领取，等待完成回调";'
assert s.count(old) == 1
s = s.replace(old, old + '\n    TKRedEvent(hasRouter?@"领取:调用TIM原生红包路由(模拟点击)":@"领取:调用兼容服务");')

# 2f. 诊断 json 加 redEvents
old = '@"classProbe":gTKClassProbeCache,'
assert s.count(old) == 1
s = s.replace(old, '@"classProbe":gTKClassProbeCache,@"redEvents":(gTKRedEvents?[gTKRedEvents copy]:@[]),')

# 2g. 版本
assert s.count('@"version":@"2.0.0"') == 2
s = s.replace('@"version":@"2.0.0"', '"version":@"2.0.1"'.join(['@', '']))
write(p, s)
print('3. 红包事件记录+探针+版本 OK')

# ================= 3. TKSettingsUI.h + control =================
p = BASE + '/TKSettingsUI.h'; s = read(p)
s = s.replace('@"2.0.0 · 双指长按唤醒"', '"2.0.1 · 双指长按唤醒"'.join(['@', '']))
s = s.replace('?:@"2.0.0"', '?:@"2.0.1"')
write(p, s)
p = '/var/minis/shared/theos-ci/debs/TIMCleanKit/control'
s = read(p); s = s.replace('Version: 2.0.0', 'Version: 2.0.1'); write(p, s)
print('4. UI/control 版本 OK')
print('ALL PATCHES APPLIED')
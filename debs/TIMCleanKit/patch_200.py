#!/usr/bin/env python3
# TIMCleanKit 2.0.0 红包路由/归档/诊断补丁（已完成，留档）。
# TIMCleanKit 2.0.0 重构补丁：
#  1) 红包领取路由重构：NTRedPackRouterService 模拟点击（TIM 真实入口）优先，QQ 服务仅兜底
#  2) 诊断加入 classProbe（探测进程内红包/钱包相关类名）
#  3) 撤回磁盘归档 TKArchiveRecalledRecord（沙盒 Application Support，上限300条）
#  4) 版本 2.0.0
import sys

BASE = '/var/minis/shared/theos-ci/debs/TIMCleanKit/TIMCleanKit'

def read(p): return open(p, encoding='utf-8').read()
def write(p, s): open(p, 'w', encoding='utf-8').write(s)

def extract_func(src, signature):
    i = src.find(signature)
    assert i >= 0, 'signature not found: ' + signature
    j = src.find('{', i)
    assert j >= 0
    depth = 0
    k = j
    while k < len(src):
        c = src[k]
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return i, k + 1
        k += 1
    raise AssertionError('unbalanced braces for: ' + signature)

# ============ 1. Tweak.xm ============
p = BASE + '/Tweak.xm'; s = read(p)

sig = 'static void TKDrainRedQueue(void) {'
a, b = extract_func(s, sig)
NEW = '''static void TKDrainRedQueue(void) {
    if(gTKAutoBusy||!gTKRedQueue.count)return;
    if(!prefBool(kEnabled,YES)||!prefBool(kAutoRed,YES)||!prefBool(kRedPacket,YES)){[gTKRedQueue removeAllObjects];return;}
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    id record=gTKRedQueue.firstObject;[gTKRedQueue removeObjectAtIndex:0];
    if(shouldSkipRedPacket(record)){TKDrainRedQueue();return;}
    UIWindow *window=UIApplication.sharedApplication.keyWindow;
    UIViewController *root=window.rootViewController;if(!root){gTKEngineStatus=@"没有可用前台窗口";return;}
    // 2.0 红包领取路由（重构）：TIM 的真实入口是 NTRedPackRouterService.handleRedPackViewClickWithRootVC:msgRecord:gesture:completion:
    //（模拟点击红包气泡，TIM 内部自行完成校验/领取/拆包全流程，已实测被 TIM 自身调用 91 次）。
    // 1.0.x 误用 QQ 内核的 QQWalletRedPacketMsgService.grabRedPackWithMsgRecord:rootVC:completion:——TIM 上该类不存在，
    // 领取请求从未真正发出（claimRequests=0 的来源）。QQ 服务仅保留为兜底。
    Class router=NSClassFromString(@"NTRedPackRouterService");
    SEL click=NSSelectorFromString(@"handleRedPackViewClickWithRootVC:msgRecord:gesture:completion:");
    BOOL hasRouter=(router!=nil)&&TKMethodABI(router,click,"v48@0:8@16@24@32@?40");
    Class service=NSClassFromString(@"QQWalletRedPacketMsgService");
    SEL claim=NSSelectorFromString(@"grabRedPackWithMsgRecord:rootVC:completion:");
    BOOL hasService=TKMethodABI(service,claim,"v40@0:8@16@24@?32");
    if(!hasRouter&&!hasService){gTKEngineStatus=@"领取服务尚未加载或签名不匹配";return;}
    id selectedWallet=redElementFromRecord(record);
    id bill=TKObjectCall(selectedWallet,@"billNo");
    gTKCurrentClaimIdentity=[bill isKindOfClass:NSString.class]?[bill copy]:nil;
    gTKAutoBusy=YES;unsigned long long generation=++gTKAutoGeneration;gTKAutoAttempts++;
    gTKEngineStatus=hasRouter?@"已调用TIM原生红包路由（模拟点击），等待完成回调":@"已调用兼容领取，等待完成回调";
    void (^completion)(id,id)=^(id result,id error){dispatch_async(dispatch_get_main_queue(),^{
        if(!gTKAutoBusy || generation!=gTKAutoGeneration)return;gTKAutoBusy=NO;
        if(error){gTKAutoErrors++;gTKEngineStatus=hasRouter?@"TIM原生红包路由返回失败，未自动重试":@"兼容领取返回失败，未自动重试";}
        else {gTKAutoCompleted++;gTKEngineStatus=@"领取流程已返回，请核对红包结果";}
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{TKDrainRedQueue();});
    });};
    if(hasRouter) {
        // 2.0: 传空手势对象（而非 nil），避免 TIM 内部读取手势坐标时异常
        UITapGestureRecognizer *placeholderGesture=[UITapGestureRecognizer new];
        ((void(*)(id,SEL,id,id,id,id))objc_msgSend)(router,click,root,record,placeholderGesture,completion);
    } else {
        ((void(*)(id,SEL,id,id,id))objc_msgSend)(service,claim,record,root,completion);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(gTKAutoBusy && generation==gTKAutoGeneration){gTKAutoBusy=NO;gTKAutoErrors++;gTKEngineStatus=@"领取超时：未收到完成回调";TKDrainRedQueue();}
    });
}'''
s = s[:a] + NEW + s[b:]
print('1. TKDrainRedQueue 重构 OK')

anchor = '    NSMutableArray *rows=[NSMutableArray array];'
assert s.count(anchor) == 1, 'rows anchor count=%d' % s.count(anchor)
probe = '''    // 2.0 诊断：探测进程内所有红包/钱包相关类名，确认 TIM 真实可用的领取服务
    static NSString *gTKClassProbeCache=nil;
    if(!gTKClassProbeCache) {
        NSMutableString *probe=[NSMutableString string];
        int classCount=objc_getClassList(NULL,0);
        if(classCount>0) {
            Class *classList=(Class*)malloc(sizeof(Class)*(size_t)classCount);
            if(classList) {
                classCount=objc_getClassList(classList,classCount);
                for(int i=0;i<classCount;i++) {
                    const char *cn=class_getName(classList[i]);
                    if(!cn)continue;
                    if(strstr(cn,"RedPack")||strstr(cn,"Wallet")||strstr(cn,"GrapHB")||strstr(cn,"Envelope")||strstr(cn,"HongBao")) {
                        [probe appendFormat:@"%s\\n",cn];
                        if(probe.length>1200)break;
                    }
                }
                free(classList);
            }
        }
        gTKClassProbeCache=probe.length?[probe copy]:@"(未找到匹配类)";
    }
'''
s = s.replace(anchor, anchor + '\n' + probe)
print('2. classProbe OK')

old = '@"hookRows":rows,'
assert s.count(old) == 1
s = s.replace(old, '@"hookRows":rows,@"classProbe":gTKClassProbeCache,')

assert s.count('@"version":@"1.0.23"') == 2, 'version count mismatch'
s = s.replace('@"version":@"1.0.23"', '"version":@"2.0.0"'.join(['@', '']))
print('3. 版本+字段 OK')
write(p, s)

# ============ 2. TKMessageBridge.h ============
p = BASE + '/TKMessageBridge.h'; s = read(p)
old = 'static void TKRestoreRecord(id record) {'
assert s.count(old) == 1
s = s.replace(old, 'static void TKArchiveRecalledRecord(id record); /* 2.0: 定义于 TKCellBridge.h，撤回内容磁盘归档 */\n' + old)
old2 = 'if(blocked){__atomic_fetch_add(&gTKRecallBlocked,1,__ATOMIC_RELAXED);TKRefreshRecallLabels();return;}'
assert s.count(old2) == 1, 'blocked branch count=%d' % s.count(old2)
s = s.replace(old2, 'if(blocked){__atomic_fetch_add(&gTKRecallBlocked,1,__ATOMIC_RELAXED);TKArchiveRecalledRecord(record);TKRefreshRecallLabels();return;}')
old3 = '// Included after message cache helpers. No chat text is logged or written to disk.'
if s.count(old3) == 1:
    s = s.replace(old3, '// Included after message cache helpers. 2.0: 被拦截的对方撤回会归档消息文本到沙盒 Application Support/TIMCleanKit/recall-archive.json（上限300条），其余场景不落盘。')
write(p, s)
print('4. TKMessageBridge.h OK')

# ============ 3. TKCellBridge.h ============
p = BASE + '/TKCellBridge.h'; s = read(p)
sig2 = 'static NSString *TKRecordTextOfElements(NSArray *elements) {'
a, b = extract_func(s, sig2)
ARCH = '''

// 2.0: 撤回消息磁盘归档——拦截到对方撤回时把消息文本快照写入沙盒;
// 独立于进程内存缓存，供后续版本做冷启动/历史撤回恢复。最多保留最近 300 条，后台队列写盘，失败静默。
static void TKArchiveRecalledRecord(id record) {
    NSString *identity=TKMessageIdentity(record);if(!identity)return;
    id elements=TKObjectCall(record,@"elements");
    NSString *text=TKRecordTextOfElements([elements isKindOfClass:NSArray.class]?elements:@[]);
    NSDictionary *context=@{@"text":text?:@"",@"time":@([[NSDate date] timeIntervalSince1970])};
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND,0),^{
        @try {
            NSString *base=[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES) firstObject];
            if(!base)return;
            NSString *dir=[base stringByAppendingPathComponent:@"TIMCleanKit"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
            NSString *path=[dir stringByAppendingPathComponent:@"recall-archive.json"];
            NSMutableDictionary *archive=[[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
            if(!archive)archive=[NSMutableDictionary dictionary];
            archive[identity]=context;
            if(archive.count>300) {
                NSArray *sorted=[archive keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){ return [a[@"time"] compare:b[@"time"]]; }];
                for(NSUInteger i=0;i+300<sorted.count;i++)[archive removeObjectForKey:sorted[i]];
            }
            NSData *data=[NSJSONSerialization dataWithJSONObject:archive options:0 error:NULL];
            [data writeToFile:path atomically:YES];
        } @catch(NSException *ignored) {}
    });
}'''
s = s[:b] + ARCH + s[b:]
write(p, s)
print('5. TKCellBridge.h 归档函数 OK')

# ============ 4. TKSettingsUI.h + control ============
p = BASE + '/TKSettingsUI.h'; s = read(p)
s = s.replace('@"1.0.23 · 双指长按唤醒"', '"2.0.0 · 双指长按唤醒"'.join(['@', '']))
s = s.replace('?:@"1.0.23"', '?:@"2.0.0"')
write(p, s)
p = '/var/minis/shared/theos-ci/debs/TIMCleanKit/control'
s = read(p); s = s.replace('Version: 1.0.23', 'Version: 2.0.0'); write(p, s)
print('6. UI/control 版本 OK')
print('ALL PATCHES APPLIED')
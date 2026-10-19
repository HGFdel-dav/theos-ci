// TWArcPXBridge.m
// 角落手势 → ParallelX 自己的面板。
//
// 为什么这样做：ParallelX 的面板（PXPanelViewController）及其弹簧动画、图标、
// 排布全部是 Swift 实现，外部只能通过 PXPanelEntry 的实例方法触发：
//     dockTapped: / dockSwiped: / dragHandle:
// 触发后动画由 ParallelX 自己跑，Twin 不画第二套，因此"动画 / 图标 / 流畅度"
// 与手柄唤醒完全一致。
//
// 角落位置：触发前把 PX 的面板窗口 panelWindow 的 anchorPoint 调到角落，
// 让 180° 半圆以角落为圆心展开（露出 90°）。改不动就维持 PX 自己的位置，
// 至少保证功能可用、不崩。
#import "TWArcPXBridge.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static __weak id gPXEntry;
static NSString *gLastResult = @"未调用";

#pragma mark - ivar helpers

static Ivar TWArcPXFindIvar(id obj, const char *name) {
    if (!obj) return NULL;
    Ivar ivar = class_getInstanceVariable([obj class], name);
    if (ivar) return ivar;
    unsigned int count = 0;
    Ivar *list = class_copyIvarList([obj class], &count);
    Ivar found = NULL;
    for (unsigned int i = 0; i < count && !found; i++) {
        const char *n = ivar_getName(list[i]);
        if (n && strcmp(n, name) == 0) found = list[i];
    }
    if (list) free(list);
    return found;
}

static id TWArcPXObject(id obj, const char *name) {
    Ivar ivar = TWArcPXFindIvar(obj, name);
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return nil;
    id value = object_getIvar(obj, ivar);
    return [(NSObject *)value isKindOfClass:NSObject.class] ? value : nil;
}

#pragma mark - public

void TWArcPXBridgeCapture(id entry) {
    if (!entry) return;
    gPXEntry = entry;
}

BOOL TWArcPXBridgeAvailable(void) {
    return gPXEntry != nil;
}

NSString *TWArcPXBridgeLastResult(void) {
    return gLastResult ?: @"";
}

// PXPanelEntry 的实例方法；不同版本可能只有其中一个。
static BOOL TWArcPXCall(id entry, NSString *selectorName, id argument) {
    SEL sel = NSSelectorFromString(selectorName);
    if (!sel || ![entry respondsToSelector:sel]) return NO;
    @try {
        NSMethodSignature *sig = [entry methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments != 3) return NO;
        ((void (*)(id, SEL, id))objc_msgSend)(entry, sel, argument);
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

// 把 PX 的面板窗口贴到角落：调 anchorPoint，让半圆的圆心落在屏幕角上。
// 只在窗口已存在时动手，失败不影响 PX 原行为。
static BOOL TWArcPXAnchorPanelAtSide(id entry, NSInteger side) {
    UIWindow *window = (UIWindow *)TWArcPXObject(entry, "panelWindow");
    if (![window isKindOfClass:[UIWindow class]]) return NO;
    CGRect screen = window.bounds;
    if (CGRectIsEmpty(screen)) return NO;

    // anchorPoint 以 0~1 表示窗口自身坐标；圆心放到底部左/右角。
    CGPoint old = window.layer.anchorPoint;
    CGPoint target = (side == 1) ? CGPointMake(0.0, 1.0) : CGPointMake(1.0, 1.0);
    if (fabs(old.x - target.x) < 0.001 && fabs(old.y - target.y) < 0.001) return YES;

    @try {
        CGRect frame = window.frame;
        window.layer.anchorPoint = target;
        window.frame = frame;                 // 保持屏幕位置不变，只挪内部原点
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

BOOL TWArcPXBridgePresent(NSInteger side) {
    id entry = gPXEntry;
    if (!entry) {
        gLastResult = @"失败：没有 PXPanelEntry 实例";
        return NO;
    }

    // 先试 dockSwiped:（PX 手柄的滑动入口），没有再退到 dockTapped:
    BOOL ok = TWArcPXCall(entry, @"dockSwiped:", nil);
    NSString *used = @"dockSwiped:";
    if (!ok) {
        ok = TWArcPXCall(entry, @"dockTapped:", nil);
        used = @"dockTapped:";
    }
    if (!ok) {
        gLastResult = @"失败：dockSwiped:/dockTapped: 都不可用";
        return NO;
    }

    // 面板窗口通常在主线程下一拍才建好，延迟一点再贴角落。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BOOL moved = TWArcPXAnchorPanelAtSide(gPXEntry, side);
        gLastResult = [NSString stringWithFormat:@"%@ 已调用；角落锚定%@",
                       used, moved ? @"成功" : @"跳过"];
    });
    gLastResult = [NSString stringWithFormat:@"%@ 已调用", used];
    return YES;
}

// CXArcWake.m
//
// ScreenCore 式角落拖拽唤醒 → 驱动 ParallelX 自己的手柄手势。
//
// PX 没有公开的"打开菜单"方法；它的菜单由 -[PXPanelEntry dragHandle:] 驱动。
// 这里在角落监听拖拽，把一段合成手势喂给 dragHandle:，
// 菜单、图标、展开动画全部由 PX 自己播放。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#import "CXArcWake.h"
#import "CXLog.h"

// 合成手势：PX 只会读 state / translationInView: / locationInView: / velocityInView:
@interface CXSynthPan : UIPanGestureRecognizer
@property (nonatomic, assign) UIGestureRecognizerState synthState;
@property (nonatomic, assign) CGPoint synthTranslation;
@property (nonatomic, assign) CGPoint synthLocation;
@property (nonatomic, assign) CGPoint synthVelocity;
@end

@implementation CXSynthPan
- (UIGestureRecognizerState)state { return self.synthState; }
- (CGPoint)translationInView:(UIView *)view { return self.synthTranslation; }
- (CGPoint)locationInView:(UIView *)view { return self.synthLocation; }
- (CGPoint)velocityInView:(UIView *)view { return self.synthVelocity; }
@end

#pragma mark - PX 对象查找

static id CXFindPanelEntry(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            NSString *name = NSStringFromClass(w.class);
            if (![name containsString:@"PXHandleWindow"]) continue;
            UIResponder *r = w.nextResponder;
            for (int i = 0; i < 10 && r; i++, r = r.nextResponder)
                if ([NSStringFromClass(r.class) isEqualToString:@"PXPanelEntry"]) return (id)r;
        }
    }
    return nil;
}

// PX 手柄视图：PXHandleWindow 里带 pan 手势的那个子视图
static UIView *CXFindHandleView(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (![NSStringFromClass(w.class) containsString:@"PXHandleWindow"]) continue;
            for (UIView *sub in w.subviews) {
                for (UIGestureRecognizer *g in sub.gestureRecognizers)
                    if ([g isKindOfClass:UIPanGestureRecognizer.class]) return sub;
                if (sub.gestureRecognizers.count) return sub;
            }
            if (w.subviews.count) return w.subviews.firstObject;
        }
    }
    return nil;
}

#pragma mark - 手势

@interface CXArcWakeGesture : UIPanGestureRecognizer <UIGestureRecognizerDelegate>
@end

@implementation CXArcWakeGesture {
    CXSynthPan *_synth;
    CGPoint _start;
    BOOL _armed;
}

- (instancetype)init {
    if ((self = [super initWithTarget:nil action:NULL])) {
        self.delegate = self;
        self.cancelsTouchesInView = NO;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
        [self addTarget:self action:@selector(handle:)];
    }
    return self;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    CGPoint p = [touch locationInView:nil];
    CGSize size = UIScreen.mainScreen.bounds.size;
    CGFloat w = 64;
    BOOL bottomLeft = (p.x < w && p.y > size.height - w);
    BOOL bottomRight = (p.x > size.width - w && p.y > size.height - w);
    if (!(bottomLeft || bottomRight)) return NO;
    _start = p;
    _armed = YES;
    return YES;
}

- (void)handle:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && !_armed) return;
    id entry = CXFindPanelEntry();
    if (!entry) { CXLog(@"[arc] 找不到 PXPanelEntry"); return; }
    SEL drag = NSSelectorFromString(@"dragHandle:");
    if (![entry respondsToSelector:drag]) { CXLog(@"[arc] dragHandle: 不存在"); return; }

    CGPoint p = [g locationInView:nil];
    CGPoint t = CGPointMake(p.x - _start.x, p.y - _start.y);

    if (g.state == UIGestureRecognizerStateBegan) {
        UIView *handle = CXFindHandleView();
        _synth = [CXSynthPan new];
        if (handle) [handle addGestureRecognizer:_synth];
        _synth.synthState = UIGestureRecognizerStateBegan;
        _synth.synthTranslation = t;
        _synth.synthLocation = p;
        CXLog(@"[arc] begin %.0f,%.0f handle=%@", p.x, p.y, NSStringFromClass(handle.class));
        @try { ((void (*)(id, SEL, id))objc_msgSend)(entry, drag, _synth); }
        @catch (__unused NSException *e) { CXLog(@"[arc] began 异常"); }
        return;
    }

    if (!_synth) return;
    _synth.synthTranslation = t;
    _synth.synthLocation = p;
    _synth.synthVelocity = [g velocityInView:nil];
    if (g.state == UIGestureRecognizerStateChanged) {
        _synth.synthState = UIGestureRecognizerStateChanged;
        @try { ((void (*)(id, SEL, id))objc_msgSend)(entry, drag, _synth); }
        @catch (__unused NSException *e) {}
    } else {
        _synth.synthState = g.state;
        @try { ((void (*)(id, SEL, id))objc_msgSend)(entry, drag, _synth); }
        @catch (__unused NSException *e) {}
        CXLog(@"[arc] end state=%ld", (long)g.state);
        UIView *handle = _synth.view;
        [handle removeGestureRecognizer:_synth];
        _synth = nil;
        _armed = NO;
    }
}

@end

static CXArcWakeGesture *CXArcGesture;

id CXArcWakeEntry(void) { return CXFindPanelEntry(); }

void CXArcWakeInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (CXArcGesture) return;
        // 不建覆盖窗口（会吞掉角落点击）；挂到现有窗口上，只观察不拦截
        int attached = 0;
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (window.hidden || !window.windowScene) continue;
            CXArcWakeGesture *g = [CXArcWakeGesture new];
            g.cancelsTouchesInView = NO;
            g.delaysTouchesBegan = NO;
            g.delaysTouchesEnded = NO;
            [window addGestureRecognizer:g];
            attached++;
        }
        id entry = CXFindPanelEntry();
        CXArcGesture = [CXArcWakeGesture new];   // 只作已安装标记
        CXLog(@"[arc] 手势已安装到 %d 个窗口（不拦截触摸）", attached);
    });
}

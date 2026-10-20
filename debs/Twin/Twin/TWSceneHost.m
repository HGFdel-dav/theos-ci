// TWSceneHost.m
// 分屏窗口底座实现（第一批）。全部私有 API 运行时解析，不引入私有头文件。
#import "TWSceneHost.h"
#import "TWRemember.h"
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 日志

static NSString *TWSHLogPath(void) {
    NSString *dir = @"/var/mobile/Library/Twin";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"scenehost.log"];
}

static void TWSHLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    FILE *f = fopen(TWSHLogPath().UTF8String, "a");
    if (!f) return;
    // 超过 256KB 就整档重写，防止日志无限膨胀。
    if (fseek(f, 0, SEEK_END) == 0 && ftell(f) > 256 * 1024) {
        fclose(f);
        f = fopen(TWSHLogPath().UTF8String, "w");
        if (!f) return;
    }
    fputs(line.UTF8String, f);
    fclose(f);
}

#pragma mark - 私有类/方法工具

static Class TWSHCls(NSString *name) { return NSClassFromString(name); }

static id TWSHCall(id obj, NSString *sel, id arg) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return nil;
    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)(obj, s, arg);
    } @catch (NSException *e) {
        TWSHLog(@"call %@ failed: %@", sel, e);
        return nil;
    }
}

// setScene:/setSceneHandle: 这类 setter 返回 void——绝不能把返回值当 BOOL 读
// （读到的是寄存器残留的垃圾值，成功可能被判成失败）。void 调用 + 异常与否判断。
static BOOL TWSHSet(id obj, NSString *sel, id arg) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return NO;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(obj, s, arg);
        return YES;
    } @catch (NSException *e) {
        TWSHLog(@"set %@ failed: %@", sel, e);
        return NO;
    }
}

// SpringBoard 的 window scene（iOS 15 起 UIWindow 必须绑定 scene）。
// 优先取前台活跃的那个，避免拿到别的 scene 导致窗口不可见。
static UIWindowScene *TWSBWindowScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        if (!fallback) fallback = ws;
    }
    return fallback;
}

#pragma mark - TWSceneHost

@interface TWSceneHost ()
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIView *hostView;
@property (nonatomic, strong) id scene;
@property (nonatomic, strong) id application;
@property (nonatomic, assign) BOOL hosting;
@end

static NSMutableDictionary<NSString *, TWSceneHost *> *TWSHRegistry(void) {
    static NSMutableDictionary *dict;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dict = [NSMutableDictionary new]; });
    return dict;
}

@implementation TWSceneHost

+ (BOOL)engineAvailable {
    return TWSHCls(@"FBSceneManager") != Nil && TWSHCls(@"_UISceneLayerHostContainerView") != Nil;
}

+ (NSArray<NSString *> *)hostedBundleIDs {
    return TWSHRegistry().allKeys;
}

+ (instancetype)hostForBundleID:(NSString *)bundleID {
    if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) return nil;
    @synchronized (TWSHRegistry()) {
        TWSceneHost *host = TWSHRegistry()[bundleID];
        if (!host) {
            host = [TWSceneHost new];   // init 里统一设默认 cornerRadius
            host->_bundleID = [bundleID copy];
            TWSHRegistry()[bundleID] = host;
        }
        return host;
    }
}

- (instancetype)init {
    if ((self = [super init])) {
        _cornerRadius = 16;
    }
    return self;
}

#pragma mark scene 解析

// 应用 scene：优先 SBApplication.mainScene，回退 FBSceneManager。
- (id)resolveScene {
    Class appCtrlCls = TWSHCls(@"SBApplicationController");
    id appCtrl = TWSHCall((id)appCtrlCls, @"sharedInstance", nil);
    if (appCtrl) {
        id app = TWSHCall(appCtrl, @"applicationWithBundleIdentifier:", self.bundleID);
        if (!app) app = TWSHCall(appCtrl, @"applicationWithBundleIdentifier:allowPlaceholder:", self.bundleID);
        if (app) {
            self.application = app;
            id scene = TWSHCall(app, @"mainScene", nil);
            if (!scene) scene = TWSHCall(app, @"scene", nil);
            if (scene) return scene;
        }
    }
    Class sceneMgrCls = TWSHCls(@"FBSceneManager");
    id sceneMgr = TWSHCall((id)sceneMgrCls, @"sharedInstance", nil);
    if (sceneMgr) {
        // 应用 scene identifier 通常就是 bundleID 或 bundleID + 后缀；逐个尝试
        for (NSString *ident in @[self.bundleID,
                                  [self.bundleID stringByAppendingString:@".scene"],
                                  [NSString stringWithFormat:@"%@-scene", self.bundleID]]) {
            id scene = TWSHCall(sceneMgr, @"sceneWithIdentifier:", ident);
            if (scene) return scene;
        }
    }
    return nil;
}

// 宿主视图：_UISceneLayerHostContainerView 承载 scene 的 layer。
- (UIView *)makeHostViewForScene:(id)scene {
    Class hostCls = TWSHCls(@"_UISceneLayerHostContainerView");
    if (!hostCls || !scene) return nil;
    UIView *host = nil;
    @try {
        host = [[hostCls alloc] initWithFrame:CGRectZero];
    } @catch (NSException *e) {
        TWSHLog(@"hostView alloc failed: %@", e);
        return nil;
    }
    // 不同系统版本 setScene:/setSceneHandle: 二选一。
    // 两者都是 void 返回，用 TWSHSet 调用（绝不能把返回值当 BOOL 读）。
    BOOL viaScene = TWSHSet(host, @"setScene:", scene);
    if (!viaScene && !TWSHSet(host, @"setSceneHandle:", scene)) {
        TWSHLog(@"hostView cannot accept scene (no setScene:/setSceneHandle:)");
        return nil;
    }
    // 走 setScene: 成功的话，用 scene getter 反查确认真挂上了（void 调用本身
    // 只能说明没抛异常，不能证明挂载生效）。
    if (viaScene && [host respondsToSelector:NSSelectorFromString(@"scene")] &&
        !TWSHCall(host, @"scene", nil)) {
        TWSHLog(@"setScene: 回查 scene 为空，挂载未生效");
        return nil;
    }
    host.backgroundColor = UIColor.blackColor;
    return host;
}

#pragma mark 生命周期

- (BOOL)present {
    if (self.hosting) return YES;
    if (!self.window) {
        UIWindowScene *ws = TWSBWindowScene();
        if (!ws) { TWSHLog(@"present %@: no window scene", self.bundleID); return NO; }
        self.window = [[UIWindow alloc] initWithWindowScene:ws];
        self.window.windowLevel = UIWindowLevelNormal + 200;
        self.window.backgroundColor = UIColor.clearColor;
        self.window.hidden = YES;
    }
    // 没设过 frame 就兜底成全屏——否则会开出 0×0 窗口却报成功，极难排查。
    if (CGRectIsEmpty(self.frame)) {
        CGRect fb = self.window.bounds;
        if (CGRectIsEmpty(fb)) fb = self.window.windowScene.coordinateSpace.bounds;
        if (!CGRectIsEmpty(fb)) {
            self.frame = fb;
            self.window.frame = fb;
        }
    } else {
        self.window.frame = self.frame;
    }
    id scene = [self resolveScene];
    if (!scene) {
        TWSHLog(@"present %@: scene not found (app not running?)", self.bundleID);
        return NO;
    }
    self.scene = scene;
    UIView *host = [self makeHostViewForScene:scene];
    if (!host) return NO;
    [self.hostView removeFromSuperview];
    self.hostView = host;
    host.frame = self.window.bounds;
    host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    host.layer.cornerRadius = self.cornerRadius;
    host.layer.masksToBounds = YES;
    [self.window addSubview:host];
    self.window.hidden = NO;
    self.hosting = YES;
    // dismiss 时实例被移出注册表；重新 present 必须把自己登记回去，
    // 否则同一 bundleID 会出现两个 host 各开各的窗口。
    @synchronized (TWSHRegistry()) {
        if (self.bundleID.length) TWSHRegistry()[self.bundleID] = self;
    }
    [self rememberCurrentFrame];
    TWSHLog(@"present %@ OK scene=%@ frame=%@", self.bundleID, scene, NSStringFromCGRect(self.frame));
    return YES;
}

// 把当前窗口 frame 写进 Twin 自己的窗口记忆（TWRemember），
// 不再依赖 ParallelX 的 PXPanelEntry 事件。
- (void)rememberCurrentFrame {
    if (!self.hosting) return;
    CGRect f = self.frame;
    // ivar 零初始化得到的是 CGRectZero（不是 Null），判空用 IsEmpty 就够。
    if (CGRectIsEmpty(f)) return;
    BOOL landscape = f.size.width > f.size.height;
    NSDictionary *rect = @{ @"x": @(f.origin.x), @"y": @(f.origin.y),
                            @"w": @(f.size.width), @"h": @(f.size.height) };
    NSDictionary *state = landscape ? @{ @"l": rect } : @{ @"p": rect };
    TWRememberStoreState(self.bundleID, self.containerID ?: @"", state);
}

- (void)setFrame:(CGRect)frame {
    _frame = frame;
    if (self.window) self.window.frame = frame;
    if (self.hostView) self.hostView.frame = self.window.bounds;
    [self rememberCurrentFrame];
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    if (self.hostView) self.hostView.layer.cornerRadius = cornerRadius;
}

- (void)dismiss {
    if (self.hosting) {
        TWSHLog(@"dismiss %@", self.bundleID);
        [self.hostView removeFromSuperview];
        self.hostView = nil;
        self.window.hidden = YES;
        self.window = nil;
        self.scene = nil;
        self.application = nil;
        self.hosting = NO;
    }
    // 无论是否成功 present 过，都把实例从注册表摘掉：
    // 否则「创建了但没 present 成功」的实例会永远占着 bundleID，
    // 泄漏并污染 hostedBundleIDs。（present 成功时会重新登记自己。）
    @synchronized (TWSHRegistry()) {
        if (self.bundleID.length && TWSHRegistry()[self.bundleID] == self) {
            [TWSHRegistry() removeObjectForKey:self.bundleID];
        }
    }
}

- (void)closeForFullscreen {
    // 第一步：先卸载 Twin 窗口（把挂载的 scene 容器视图摘掉）。
    NSString *bid = [self.bundleID copy];
    [self dismiss];
    if (!bid.length) return;
    // 第二步：尽力把应用交还系统前台。只删视图的话，若挂载期间系统侧的
    // 全屏呈现被顶掉，会出现「关了分屏但应用黑屏回不来」。这里请求系统把
    // 该应用重新激活为全屏——目标状态正是「回到系统全屏」，即使系统本来就
    // 持有 scene，重复激活也只是普通的置前，无副作用。
    // 接口不存在/抛异常时静默记录并跳过，绝不崩 SpringBoard。
    id workspace = TWSHCall((id)TWSHCls(@"LSApplicationWorkspace"), @"defaultWorkspace", nil);
    SEL openSel = NSSelectorFromString(@"openApplicationWithIdentifier:");
    if ([workspace respondsToSelector:openSel]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(workspace, openSel, bid);
            TWSHLog(@"closeForFullscreen: 已请求系统重新前台 %@", bid);
        } @catch (NSException *e) {
            TWSHLog(@"closeForFullscreen: openApplication 失败 %@", e);
        }
    } else {
        TWSHLog(@"closeForFullscreen: 无 openApplication 接口，仅卸载窗口（若应用没回来请带日志反馈）");
    }
}

@end

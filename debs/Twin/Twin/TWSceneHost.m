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
    if (f) { fputs(line.UTF8String, f); fclose(f); }
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

static BOOL TWSHCallBool(id obj, NSString *sel, id arg) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return NO;
    @try {
        return ((BOOL (*)(id, SEL, id))objc_msgSend)(obj, s, arg);
    } @catch (NSException *e) { return NO; }
}

// SpringBoard 的 window scene（iOS 15 起 UIWindow 必须绑定 scene）
static UIWindowScene *TWSBWindowScene(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)s;
    }
    return nil;
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
            host = [TWSceneHost new];
            host->_bundleID = [bundleID copy];
            host->_cornerRadius = 16;
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
    // 不同系统版本 setScene:/setSceneHandle: 二选一
    if (!TWSHCallBool(host, @"setScene:", scene) &&
        !TWSHCallBool(host, @"setSceneHandle:", scene)) {
        TWSHLog(@"hostView cannot accept scene (no setScene:/setSceneHandle:)");
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
    self.window.frame = self.frame;
    self.window.hidden = NO;
    self.hosting = YES;
    [self rememberCurrentFrame];
    TWSHLog(@"present %@ OK scene=%@ frame=%@", self.bundleID, scene, NSStringFromCGRect(self.frame));
    return YES;
}

// 把当前窗口 frame 写进 Twin 自己的窗口记忆（TWRemember），
// 不再依赖 ParallelX 的 PXPanelEntry 事件。
- (void)rememberCurrentFrame {
    if (!self.hosting) return;
    CGRect f = self.frame;
    if (CGRectIsNull(f) || CGRectIsEmpty(f)) return;
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
    if (!self.hosting) return;
    TWSHLog(@"dismiss %@", self.bundleID);
    [self.hostView removeFromSuperview];
    self.hostView = nil;
    self.window.hidden = YES;
    self.window = nil;
    self.scene = nil;
    self.application = nil;
    self.hosting = NO;
    @synchronized (TWSHRegistry()) {
        [TWSHRegistry() removeObjectForKey:self.bundleID];
    }
}

- (void)closeForFullscreen {
    // 第一批：直接卸载 Twin 窗口，让应用回到系统全屏（scene 仍由系统持有）。
    [self dismiss];
}

@end

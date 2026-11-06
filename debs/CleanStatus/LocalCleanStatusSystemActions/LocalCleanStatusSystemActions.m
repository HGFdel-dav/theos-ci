#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>
#import "LocalCleanStatusPaths.h"
#import "ControlCenterUIKit/CCUIContentModule.h"
#import "ControlCenterUIKit/CCUIButtonModuleViewController.h"
#import "ControlCenterUIKit/CCUIMenuModuleViewController.h"
#import "ControlCenterUIKit/CCUIContentModuleContext.h"
#import "LocalCleanStatusPaths.h"

// Standard Control Center module. Long press (native expansion) shows the menu.
// Actions request system services directly; no shell, no root helper, no
// /var/jb paths. Unavailable backends are omitted instead of faked.

typedef NS_OPTIONS(unsigned long long, LCSCLaunchOptions) {
    LCSCLaunchOptionsNone = 0,
    LCSCLaunchOptionsRestartRenderServer = 1ULL << 0
};

@interface LCSCLaunchAction : NSObject
+ (instancetype)actionWithReason:(NSString *)reason options:(LCSCLaunchOptions)options targetURL:(NSURL *)url;
@end

@interface LCSCSystemService : NSObject
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(void (^)(id error))result;
- (void)reboot;
- (void)shutdown;
@end

static LCSCSystemService *LCSCCService(void) {
    Class cls = NSClassFromString(@"FBSSystemService");
    SEL selector = sel_registerName("sharedService");
    return (cls && [cls respondsToSelector:selector]) ? ((id(*)(id,SEL))objc_msgSend)(cls, selector) : nil;
}
static BOOL LCSCRespringAvailable(void) {
    Class cls = NSClassFromString(@"SBSRelaunchAction");
    return cls && [cls respondsToSelector:sel_registerName("actionWithReason:options:targetURL:")] &&
        [LCSCCService() respondsToSelector:sel_registerName("sendActions:withResult:")];
}
static BOOL LCSCRebootAvailable(void) { return [LCSCCService() respondsToSelector:sel_registerName("reboot")]; }
static BOOL LCSCShutdownAvailable(void) { return [LCSCCService() respondsToSelector:sel_registerName("shutdown")]; }

extern char **environ;

// Helper binaries resolve through the hidden root, never a hardcoded /var/jb.
static BOOL LCSCRunTool(NSString *tool, NSArray<NSString *> *arguments, NSError **error) {
    NSString *path = local_cleanstatus_toolPath(tool);
    if (!path) {
        if (error) *error = [NSError errorWithDomain:@"CleanStatusCC" code:1
            userInfo:@{NSLocalizedDescriptionKey:[tool stringByAppendingString:@" 不存在"]}];
        return NO;
    }
    NSMutableArray<NSString *> *argv = [NSMutableArray arrayWithObject:path];
    [argv addObjectsFromArray:arguments];
    char **vector = calloc(argv.count + 1, sizeof(char *));
    if (!vector) return NO;
    for (NSUInteger i = 0; i < argv.count; i++) vector[i] = strdup(argv[i].UTF8String);
    pid_t pid = 0;
    int status = posix_spawn(&pid, path.fileSystemRepresentation, NULL, NULL, vector, environ);
    for (NSUInteger i = 0; i < argv.count; i++) free(vector[i]);
    free(vector);
    if (status != 0) {
        if (error) *error = [NSError errorWithDomain:@"CleanStatusCC" code:status
            userInfo:@{NSLocalizedDescriptionKey:@"启动失败"}];
        return NO;
    }
    return YES;
}
static BOOL LCSCUserspaceAvailable(void) {
    return local_cleanstatus_toolPath(@"launchctl") != nil;
}
static BOOL LCSCToolAvailable(NSString *tool) { return local_cleanstatus_toolPath(tool) != nil; }
static void LCSCUserspaceReboot(void) { LCSCRunTool(@"launchctl", @[@"reboot", @"userspace"], NULL); }
static void LCSCSafeMode(void) { LCSCRunTool(@"killall", @[@"-SEGV", @"SpringBoard"], NULL); }

static void LCSCRespring(void) {
    Class cls = NSClassFromString(@"SBSRelaunchAction");
    LCSCSystemService *service = LCSCCService();
    if (!LCSCRespringAvailable()) return;
    id action = ((id(*)(id,SEL,id,LCSCLaunchOptions,id))objc_msgSend)(cls,
        sel_registerName("actionWithReason:options:targetURL:"),
        @"CleanStatus.Respring", LCSCLaunchOptionsRestartRenderServer, nil);
    if (action) ((void(*)(id,SEL,id,id))objc_msgSend)(service,
        sel_registerName("sendActions:withResult:"), [NSSet setWithObject:action], nil);
}
static void LCSCReboot(void) {
    LCSCSystemService *service = LCSCCService();
    if (LCSCRebootAvailable()) ((void(*)(id,SEL))objc_msgSend)(service, sel_registerName("reboot"));
}
static void LCSCShutdown(void) {
    LCSCSystemService *service = LCSCCService();
    if (LCSCShutdownAvailable()) ((void(*)(id,SEL))objc_msgSend)(service, sel_registerName("shutdown"));
}

@interface LCSCSystemActionsController : CCUIMenuModuleViewController
@property(nonatomic, weak) CCUIContentModuleContext *context;
@property(nonatomic) BOOL busy;
@end

static BOOL LCSCEnabled(void) {
    NSString *path = local_cleanstatus_preferencesPath();
    NSDictionary *values = path.length ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    id value = values[@"ccSystemActions"];
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}

@implementation LCSCSystemActionsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.glyphImage = [UIImage systemImageNamed:@"power"];
    [self rebuildMenu];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rebuildMenu];
}
- (void)rebuildMenu {
    [self removeAllActions];
    BOOL enabled = LCSCEnabled();
    self.title = enabled ? @"系统操作" : @"系统操作（已关闭）";
    if (!enabled) return;
    __weak typeof(self) weakSelf = self;
    if (LCSCRespringAvailable())
        [self addActionWithTitle:@"注销桌面" glyph:[UIImage systemImageNamed:@"arrow.clockwise.circle"]
                         handler:^{ [weakSelf run:^{ LCSCRespring(); }]; }];
    if (LCSCToolAvailable(@"killall"))
        [self addActionWithTitle:@"安全模式" glyph:[UIImage systemImageNamed:@"shield.lefthalf.filled"]
                         handler:^{ [weakSelf run:^{ LCSCSafeMode(); }]; }];
    if (LCSCUserspaceAvailable())
        [self addActionWithTitle:@"用户空间重启" glyph:[UIImage systemImageNamed:@"exclamationmark.arrow.triangle.2.circlepath"]
                         handler:^{ [weakSelf run:^{ LCSCUserspaceReboot(); }]; }];
    if (LCSCRebootAvailable())
        [self addActionWithTitle:@"重新启动" glyph:[UIImage systemImageNamed:@"restart"]
                         handler:^{ [weakSelf run:^{ LCSCReboot(); }]; }];
    if (LCSCShutdownAvailable())
        [self addActionWithTitle:@"关机" glyph:[UIImage systemImageNamed:@"power"]
                         handler:^{ [weakSelf run:^{ LCSCShutdown(); }]; }];
}
- (void)run:(void (^)(void))action {
    if (self.busy) return;
    self.busy = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:@"com.local.cleanstatus.cc.action"
        object:nil userInfo:@{@"name": self.title ?: @""}];
    dispatch_async(dispatch_get_main_queue(), ^{ action(); });
}
- (BOOL)shouldBeginTransitionToExpandedContentModule {
    return self.actionsCount > 0;
}
- (void)buttonTapped:(id)sender forEvent:(id)event {
    (void)sender; (void)event;
    [self.context requestExpandModule];
}
@end

@interface LCSCSystemActionsModule : NSObject <CCUIContentModule> {
    LCSCSystemActionsController *_controller;
}
@end

@implementation LCSCSystemActionsModule
- (instancetype)init {
    if ((self = [super init])) _controller = [LCSCSystemActionsController new];
    return self;
}
- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController { return _controller; }
- (UIViewController *)backgroundViewController { return nil; }
- (void)setContentModuleContext:(CCUIContentModuleContext *)context { _controller.context = context; }
@end

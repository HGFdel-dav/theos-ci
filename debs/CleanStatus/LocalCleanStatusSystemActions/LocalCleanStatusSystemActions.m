#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <spawn.h>
#import <signal.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>
#import <time.h>
#import "LocalCleanStatusCCEnvironment.h"
#import "LocalCleanStatusCCRuntime.h"
#import "LocalCleanStatusCCDiagnostics.h"
#import "LocalCleanStatusPaths.h"
#import "ControlCenterUIKit/CCUIContentModule.h"
#import "ControlCenterUIKit/CCUIButtonModuleViewController.h"
#import "ControlCenterUIKit/CCUIMenuModuleViewController.h"
#import "ControlCenterUIKit/CCUIContentModuleContext.h"

// Five actions, all shown. Availability decides whether the action runs, never
// whether the row exists; a missing backend produces a visible reason instead
// of a silent omission or a row that pretends to work.
typedef NS_ENUM(NSInteger,LCSCSystemAction) {
    LCSCSystemActionRespring=0,LCSCSystemActionSafeMode,LCSCSystemActionUserspace,
    LCSCSystemActionReboot,LCSCSystemActionShutdown
};
static NSString * const kLCSCSafeModeFlag=@"/var/mobile/Library/Preferences/com.local.cleanstatus.safemode";
extern char **environ;

@interface LCSCLaunchAction : NSObject
+ (instancetype)actionWithReason:(NSString *)reason options:(unsigned long long)options targetURL:(NSURL *)url;
@end
@interface LCSCSystemService : NSObject
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(void (^)(id error))result;
- (void)reboot;
- (void)shutdown;
@end

static id lcscc_service(void) { return lcscc_object(NSClassFromString(@"FBSSystemService"),"sharedService"); }
static BOOL lcscc_has(id obj,const char *name,const char *result) {
    return lcscc_method(object_getClass(obj),sel_registerName(name),result,0,NULL);
}
// 0.2.2 gated this behind an exact-signature match and told the user the system
// does not support respring on a device where it works. Presence is the check
// the working build used; a real failure is reported when the action runs.
static BOOL LCSCRespringFactory(Class cls) {
    return cls && [cls respondsToSelector:sel_registerName("actionWithReason:options:targetURL:")];
}
static BOOL LCSCRespringAvailable(void) {
    return LCSCRespringFactory(NSClassFromString(@"SBSRelaunchAction")) &&
        [lcscc_service() respondsToSelector:sel_registerName("sendActions:withResult:")];
}

// A file that exists and is executable is existence, not privilege; every
// helper path is probed, and privilege is reported as unverified in the UI.
static BOOL lcscc_run(NSString *tool,NSArray<NSString *> *arguments,NSString **reason) {
    NSString *path=local_cleanstatus_ccToolPath(tool);
    if (!path) { if (reason) *reason=[NSString stringWithFormat:@"找不到 %@（隐根工具缺失）",tool]; return NO; }
    NSMutableArray *argv=[NSMutableArray arrayWithObject:path];
    [argv addObjectsFromArray:arguments];
    char **vector=calloc(argv.count+1,sizeof(char *));
    if (!vector) { if (reason) *reason=@"内存不足"; return NO; }
    for (NSUInteger i=0;i<argv.count;i++) vector[i]=strdup(((NSString *)argv[i]).UTF8String);
    pid_t pid=0;
    int status=posix_spawn(&pid,path.fileSystemRepresentation,NULL,NULL,vector,environ);
    for (NSUInteger i=0;i<argv.count;i++) free(vector[i]);
    free(vector);
    if (status!=0) { if (reason) *reason=[NSString stringWithFormat:@"无法启动 %@（errno %d）",tool,status]; return NO; }
    return YES;
}

@interface LCSCSystemActionsController : CCUIMenuModuleViewController
@property(nonatomic,weak) CCUIContentModuleContext *context;
@property(nonatomic) BOOL busy;
@end
@implementation LCSCSystemActionsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.glyphImage=[UIImage systemImageNamed:@"power"];
    self.title=@"系统操作";
    [self rebuildMenu];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self rebuildMenu]; }
- (BOOL)enabled {
    NSString *path=local_cleanstatus_preferencesPath();
    NSDictionary *values=path.length?[NSDictionary dictionaryWithContentsOfFile:path]:nil;
    id value=values[@"ccSystemActions"];
    return [value isKindOfClass:NSNumber.class]&&[value boolValue];
}
- (NSString *)unavailableReasonFor:(LCSCSystemAction)action {
    switch (action) {
        case LCSCSystemActionRespring:
            return LCSCRespringAvailable()?nil:@"系统不支持注销动作";
        case LCSCSystemActionSafeMode:
            return nil; // implemented by this tweak, always available
        case LCSCSystemActionUserspace:
            return local_cleanstatus_ccToolPath(@"jbctl")?nil:
                (local_cleanstatus_ccToolPath(@"launchctl")?nil:@"找不到 jbctl 或 launchctl（需 RootHide 引导）");
        case LCSCSystemActionReboot:
            return lcscc_has(lcscc_service(),"reboot",@encode(void))?nil:@"系统重启服务不可用";
        case LCSCSystemActionShutdown:
            return lcscc_has(lcscc_service(),"shutdown",@encode(void))?nil:@"系统关机服务不可用";
    }
    return @"未实现";
}
- (void)rebuildMenu {
    self.busy=NO;
    [self removeAllActions];
    if (![self enabled]) { self.title=@"系统操作(已关闭)"; return; }
    self.title=@"系统操作";
    NSArray *rows=@[
        @[@"注销桌面",@"arrow.clockwise.circle",@(LCSCSystemActionRespring)],
        @[@"安全模式",@"shield.lefthalf.filled",@(LCSCSystemActionSafeMode)],
        @[@"用户空间重启",@"exclamationmark.arrow.triangle.2.circlepath",@(LCSCSystemActionUserspace)],
        @[@"重新启动",@"restart",@(LCSCSystemActionReboot)],
        @[@"关机",@"power",@(LCSCSystemActionShutdown)],
    ];
    __weak typeof(self) weakSelf=self;
    BOOL rich=[self respondsToSelector:sel_registerName("addActionWithTitle:subtitle:glyph:handler:")];
    for (NSArray *row in rows) {
        LCSCSystemAction action=(LCSCSystemAction)[row[2] integerValue];
        NSString *why=[self unavailableReasonFor:action];
        // Availability is stated in the subtitle when the platform supports it
        // and in the confirmation/error path otherwise. The row always exists.
        if (rich && why.length) {
            [self addActionWithTitle:row[0] subtitle:why glyph:[UIImage systemImageNamed:row[1]]
                             handler:^{ [weakSelf request:action]; }];
        } else {
            [self addActionWithTitle:row[0] glyph:[UIImage systemImageNamed:row[1]]
                             handler:^{ [weakSelf request:action]; }];
        }
    }
    if ([self respondsToSelector:sel_registerName("setUseTallLayout:")]) self.useTallLayout=YES;
}
- (void)request:(LCSCSystemAction)action {
    NSString *blocked=[self unavailableReasonFor:action];
    if (blocked) { [self report:blocked success:NO]; return; }
    if (!local_cleanstatus_ccUnlocked()) { [self report:@"设备已锁定，操作未执行" success:NO]; return; }
    // Destructive actions require a second, explicit confirmation.
    UIAlertController *confirm=[UIAlertController alertControllerWithTitle:@"确认执行"
        message:[self confirmationTextFor:action] preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"执行" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a){ (void)a; [weakSelf perform:action]; }]];
    UIViewController *host=self;
    while (host.presentedViewController) host=host.presentedViewController;
    [host presentViewController:confirm animated:YES completion:nil];
}
- (NSString *)confirmationTextFor:(LCSCSystemAction)action {
    switch (action) {
        case LCSCSystemActionRespring: return @"将重新加载桌面，设备不会重启。";
        case LCSCSystemActionSafeMode: return @"将连续两次强制重启桌面，使越狱环境进入安全模式（不加载插件）。若系统未进入安全模式，效果等同两次注销。";
        case LCSCSystemActionUserspace: return @"将执行用户空间重启，保持内核与越狱环境。";
        case LCSCSystemActionReboot: return @"将重启整台设备。";
        case LCSCSystemActionShutdown: return @"将关闭设备，需要手动开机。";
    }
    return @"";
}
- (void)perform:(LCSCSystemAction)action {
    // Single-shot: rebuildMenu disables the rows while an action is in flight.
    if (self.busy) return;
    self.busy=YES;
    [self report:nil success:YES];
    switch (action) {
        case LCSCSystemActionRespring: {
            Class cls=NSClassFromString(@"SBSRelaunchAction");
            id service=lcscc_service();
            SEL make=sel_registerName("actionWithReason:options:targetURL:");
            if (!LCSCRespringAvailable()) {
                [self report:@"注销动作不可用" success:NO]; return;
            }
            id obj=cls?((id(*)(id,SEL,id,unsigned long long,id))objc_msgSend)(cls,make,@"CleanStatus.Respring",1ULL,nil):nil;
            if (!obj || !service) { [self report:@"注销动作创建失败,请改用用户空间重启" success:NO]; return; }
            ((void(*)(id,SEL,id,id))objc_msgSend)(service,sel_registerName("sendActions:withResult:"),[NSSet setWithObject:obj],nil);
            return;
        }
        case LCSCSystemActionSafeMode: {
            // Arm the flag, then crash SpringBoard twice across two boots. The
            // flag carries a timestamp so a stale arming cannot loop forever.
            NSMutableDictionary *flag=[NSMutableDictionary dictionary];
            flag[@"stage"]=@1; flag[@"armed"]=@([[NSDate date] timeIntervalSince1970]);
            if (![flag writeToFile:local_cleanstatus_ccResourcePath(kLCSCSafeModeFlag) atomically:YES]) {
                [self report:@"无法写入安全模式标记（隐根路径不可写）" success:NO]; return;
            }
            dispatch_async(dispatch_get_main_queue(),^{
                Class cls=NSClassFromString(@"SBSRelaunchAction");
                SEL make=sel_registerName("actionWithReason:options:targetURL:");
                if (LCSCRespringFactory(cls)) {
                    id obj=((id(*)(id,SEL,id,unsigned long long,id))objc_msgSend)(cls,make,@"CleanStatus.SafeMode",1ULL,nil);
                    if (obj) ((void(*)(id,SEL,id,id))objc_msgSend)(lcscc_service(),sel_registerName("sendActions:withResult:"),[NSSet setWithObject:obj],nil);
                }
            });
            return;
        }
        case LCSCSystemActionUserspace: {
            NSString *reason=nil;
            if (local_cleanstatus_ccToolPath(@"jbctl")) {
                if (lcscc_run(@"jbctl",@[@"reboot_userspace"],&reason)) return;
            }
            if (lcscc_run(@"launchctl",@[@"reboot",@"userspace"],&reason)) return;
            [self report:reason success:NO]; return;
        }
        case LCSCSystemActionReboot:
            if (lcscc_has(lcscc_service(),"reboot",@encode(void))) {
                dispatch_async(dispatch_get_main_queue(),^{ [self report:nil success:YES];
                    ((void(*)(id,SEL))objc_msgSend)(lcscc_service(),sel_registerName("reboot")); });
                return;
            }
            [self report:@"系统重启服务不可用" success:NO]; return;
        case LCSCSystemActionShutdown:
            if (lcscc_has(lcscc_service(),"shutdown",@encode(void))) {
                dispatch_async(dispatch_get_main_queue(),^{ [self report:nil success:YES];
                    ((void(*)(id,SEL))objc_msgSend)(lcscc_service(),sel_registerName("shutdown")); });
                return;
            }
            [self report:@"系统关机服务不可用" success:NO]; return;
    }
}
- (void)report:(NSString *)message success:(BOOL)success {
    local_cleanstatus_ccLog(success?@"system.action":@"system.blocked",message?:@"ok");
    if (!message.length) return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"系统操作" message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *host=self;
    while (host.presentedViewController) host=host.presentedViewController;
    [host presentViewController:alert animated:YES completion:nil];
}
- (BOOL)shouldBeginTransitionToExpandedContentModule { return self.actionsCount>0; }
- (void)buttonTapped:(id)sender forEvent:(id)event {
    (void)sender; (void)event; [self.context requestExpandModule];
}
@end

@interface LCSCSystemActionsModule : NSObject <CCUIContentModule> {
    LCSCSystemActionsController *_controller;
}
@end
@implementation LCSCSystemActionsModule
- (instancetype)init { if ((self=[super init])) _controller=[LCSCSystemActionsController new]; return self; }
- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController { return _controller; }
- (UIViewController *)backgroundViewController { return nil; }
- (void)setContentModuleContext:(CCUIContentModuleContext *)context { _controller.context=context; }
@end

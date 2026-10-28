#import "PXPAccounts.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>
#include <signal.h>
#include <errno.h>

NSErrorDomain const PXPAccountsErrorDomain = @"PXPAccountsErrorDomain";
NSString * const PXPDefaultContainerIdentifier = @"DEFAULT";

/* Evidence: ScreenCore 2.0.5 arm64e, sc-clone-research/open-target.annotated.asm:
 * 4a104/108/10c: x2=container, x3=bundle, x4=copied block (THREE arguments).
 * Block invoke 4a18c; descriptor 99868, signature pointer at 99888 -> 7c59c:
 * "v12@?0B8". This is void (^)(BOOL), NOT void (^)(void), nor a fourth BOOL.
 * termination: 5c954..964, FBSystemService sharedInstance, reason=1/report=YES;
 * global completion at 99d48 -> descriptor 985a8 -> "v8@?0" (no arguments).
 * Runtime method encodings are still checked before EVERY private invocation.
 * No runtime encoding can attest the nested signature of an arbitrary @?;
 * this implementation supports the evidenced ABI only, not arbitrary versions.
 */
static NSString * const PXPBioSelector = @"setActiveContainerIdentifier:forApplicationWithIdentifier:usingBiometricsIfNeededWithSuccessHandler:";
static NSString * const PXPTerminateSelector = @"terminateApplication:forReason:andReport:withDescription:completion:";

static NSError *PXPError(PXPAccountsErrorCode code, NSString *text) {
    return [NSError errorWithDomain:PXPAccountsErrorDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey:text}];
}
static BOOL PXPString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0;
}
static BOOL PXPType(const char *actual, const char *expected) {
    if (!actual) return NO;
    if (strcmp(expected, "@") == 0) {
        if (strcmp(actual, "@") == 0) return YES;
        size_t n = strlen(actual);
        return n >= 4 && actual[0] == '@' && actual[1] == '"' && actual[n-1] == '"';
    }
    return strcmp(actual, expected) == 0;
}
static BOOL PXPSignature(id target, NSString *name, const char *result, NSArray<NSString *> *args) {
    SEL sel = NSSelectorFromString(name);
    if (!target || ![target respondsToSelector:sel]) return NO;
    Method method = class_getInstanceMethod(object_getClass(target), sel);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding) return NO; // No forwarding or guessed NSInvocation ABI.
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:encoding];
    if (!sig || sig.numberOfArguments != args.count + 2 || !PXPType(sig.methodReturnType, result) ||
        !PXPType([sig getArgumentTypeAtIndex:0], "@") ||
        strcmp([sig getArgumentTypeAtIndex:1], ":") != 0) return NO;
    for (NSUInteger i = 0; i < args.count; ++i)
        if (!PXPType([sig getArgumentTypeAtIndex:i+2], args[i].UTF8String)) return NO;
    return YES;
}
static void PXPRequire(id target, NSString *name, const char *result, NSArray *args) {
    if (!PXPSignature(target, name, result, args))
        @throw [NSException exceptionWithName:@"PXPUnsupportedABI" reason:name userInfo:nil];
}
static id PXPObject0(id target, NSString *name) {
    PXPRequire(target, name, "@", @[]);
    return ((id (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(name));
}
static id PXPObject1(id target, NSString *name, id arg) {
    PXPRequire(target, name, "@", @[@"@"]);
    return ((id (*)(id, SEL, id))objc_msgSend)(target, NSSelectorFromString(name), arg);
}
static BOOL PXPBool0(id target, NSString *name) {
    PXPRequire(target, name, @encode(BOOL), @[]);
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(name));
}
static NSError *PXPException(NSException *e) {
    return PXPError(PXPAccountsUnsupportedABI, [@"Unsupported private API: " stringByAppendingString:e.reason ?: e.name]);
}
static id PXPManager(void) {
    Class cls = NSClassFromString(@"CraneManager");
    if (!cls) return nil; // Host must load Crane normally; no filesystem/dlopen guesses.
    id manager = PXPObject0(cls, @"sharedManager");
    return [manager isKindOfClass:cls] ? manager : nil;
}
static BOOL PXPSupported(id manager, NSString *bundle) {
    NSString *name = @"isApplicationSupportedByCrane:";
    PXPRequire(manager, name, @encode(BOOL), @[@"@"]);
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(manager, NSSelectorFromString(name), bundle);
}
static NSString *PXPActive(id manager, NSString *bundle) {
    id active = PXPObject1(manager, @"activeContainerIdentifierForApplicationWithIdentifier:", bundle);
    return PXPString(active) ? [active copy] : nil; // nil is NOT DEFAULT.
}
static NSArray<NSDictionary *> *PXPContainers(id manager, NSString *bundle, NSError **error) {
    if (!manager || !PXPSupported(manager, bundle)) {
        *error = PXPError(PXPAccountsUnavailable, @"Crane is unavailable or does not support this application.");
        return nil;
    }
    // prefs-crane 1c888..1c930: settings dictionary -> Containers array -> identifier/name.
    id settings = PXPObject1(manager, @"applicationSettingsForApplicationWithIdentifier:", bundle);
    id raw = [settings isKindOfClass:NSDictionary.class] ? settings[@"Containers"] : nil;
    if (![raw isKindOfClass:NSArray.class]) {
        *error = PXPError(PXPAccountsInvalidData, @"Unrecognized Crane Containers structure.");
        return nil;
    }
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    BOOL hasDefault = NO;
    for (id row in raw) {
        if (![row isKindOfClass:NSDictionary.class] || !PXPString(row[@"identifier"]) ||
            !PXPString(row[@"name"]) || [seen containsObject:row[@"identifier"]]) {
            *error = PXPError(PXPAccountsInvalidData, @"Malformed or duplicate Crane container.");
            return nil; // Do not silently discard an unknown account.
        }
        NSString *identifier = [row[@"identifier"] copy];
        [seen addObject:identifier];
        hasDefault |= [identifier isEqualToString:PXPDefaultContainerIdentifier];
        [rows addObject:@{@"identifier":identifier, @"name":[row[@"name"] copy]}];
    }
    // DEFAULT is an explicit real target, also when omitted from the non-default list.
    if (!hasDefault) [rows insertObject:@{@"identifier":PXPDefaultContainerIdentifier, @"name":@"主账号 (DEFAULT)"} atIndex:0];
    return [rows copy];
}
static BOOL PXPContains(NSArray<NSDictionary *> *rows, NSString *identifier) {
    for (NSDictionary *row in rows) if ([row[@"identifier"] isEqualToString:identifier]) return YES;
    return NO;
}
BOOL PXPAccountsAvailable(void) {
    if (!NSThread.isMainThread) return NO;
    @try {
        id manager = PXPManager();
        return PXPSignature(manager, @"applicationSettingsForApplicationWithIdentifier:", "@", @[@"@"]) &&
               PXPSignature(manager, @"isApplicationSupportedByCrane:", @encode(BOOL), @[@"@"]) &&
               PXPSignature(manager, @"activeContainerIdentifierForApplicationWithIdentifier:", "@", @[@"@"]) &&
               PXPSignature(manager, PXPBioSelector, "v", @[@"@", @"@", @"@?"]);
    } @catch (__unused NSException *e) { return NO; }
}
BOOL PXPAccountStillMatches(NSString *bundle, NSString *containerID) {
    if (!NSThread.isMainThread || !PXPString(bundle) || !PXPString(containerID)) return NO;
    @try {
        id manager = PXPManager();
        NSError *error = nil;
        NSArray *rows = PXPContainers(manager, bundle, &error);
        // Only active preference equality. NOT proof of a running process environment.
        return rows && PXPContains(rows, containerID) && [PXPActive(manager, bundle) isEqualToString:containerID];
    } @catch (__unused NSException *e) { return NO; }
}

@class PXPPreparation;
static PXPPreparation *PXPPreparing; // Main-only global serialization, including abandoned authentication.
@interface PXPPicker : UITableViewController
@property(nonatomic, copy) NSArray<NSDictionary *> *rows;
@property(nonatomic, copy) void (^finish)(NSString *, NSError *);
@property(nonatomic, strong) UIWindow *ownedWindow;
@property(nonatomic, weak) UIWindow *previousKeyWindow;
@property(nonatomic, strong) id backgroundObserver;
@property(nonatomic, strong) id disconnectObserver;
- (void)complete:(NSString *)identifier error:(NSError *)error;
@end
static PXPPicker *PXPPicking;
@implementation PXPPicker
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择账号";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
}
- (void)cancel { [self complete:nil error:PXPError(PXPAccountsCancelled, @"Account selection cancelled.")]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.rows.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = self.rows[indexPath.row][@"name"];
    cell.detailTextLabel.text = self.rows[indexPath.row][@"identifier"];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self complete:self.rows[indexPath.row][@"identifier"] error:nil];
}
- (void)complete:(NSString *)identifier error:(NSError *)error {
    NSAssert(NSThread.isMainThread, @"main only");
    if (!self.finish) return;
    void (^callback)(NSString *, NSError *) = self.finish;
    self.finish = nil;
    if (self.backgroundObserver) [NSNotificationCenter.defaultCenter removeObserver:self.backgroundObserver];
    if (self.disconnectObserver) [NSNotificationCenter.defaultCenter removeObserver:self.disconnectObserver];
    self.backgroundObserver = nil;
    self.disconnectObserver = nil;
    BOOL restore = self.ownedWindow.isKeyWindow;
    self.ownedWindow.hidden = YES;
    self.ownedWindow.rootViewController = nil;
    self.ownedWindow = nil;
    if (restore && !self.previousKeyWindow.hidden && self.previousKeyWindow.windowScene.activationState == UISceneActivationStateForegroundActive)
        [self.previousKeyWindow makeKeyWindow];
    if (PXPPicking == self) PXPPicking = nil;
    callback(identifier, error);
}
@end

void PXPCancelAccountSelection(void) {
    if (NSThread.isMainThread) [PXPPicking cancel];
}

void PXPChooseAccount(NSString *bundle, void (^completion)(NSString *, NSError *)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!completion) return;
        __block BOOL replied = NO;
        void (^reply)(NSString *, NSError *) = ^(NSString *identifier, NSError *error) {
            if (replied) return;
            replied = YES;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(identifier, error); });
        };
        if (!PXPString(bundle)) { reply(nil, PXPError(PXPAccountsInvalidArgument, @"Missing bundle identifier.")); return; }
        if (PXPPicking || PXPPreparing) { reply(nil, PXPError(PXPAccountsBusy, @"An account transaction is busy.")); return; }
        @try {
            NSError *error = nil;
            NSArray *rows = PXPContainers(PXPManager(), bundle, &error);
            if (!rows) { reply(nil, error); return; }
            if (rows.count == 1) { reply(rows[0][@"identifier"], nil); return; }
            UIWindowScene *scene = nil;
            for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
                if ([candidate isKindOfClass:UIWindowScene.class] && candidate.activationState == UISceneActivationStateForegroundActive) {
                    if (scene) { reply(nil, PXPError(PXPAccountsNotForeground, @"Ambiguous foreground scene.")); return; }
                    scene = (UIWindowScene *)candidate;
                }
            }
            if (!scene) { reply(nil, PXPError(PXPAccountsNotForeground, @"No active scene for account selection.")); return; }
            PXPPicker *picker = [[PXPPicker alloc] initWithStyle:UITableViewStyleInsetGrouped];
            picker.rows = rows;
            picker.finish = [reply copy];
            PXPPicking = picker;
            for (UIWindow *window in scene.windows) if (window.isKeyWindow) picker.previousKeyWindow = window;
            picker.ownedWindow = [[UIWindow alloc] initWithWindowScene:scene];
            picker.ownedWindow.frame = scene.coordinateSpace.bounds;
            picker.ownedWindow.windowLevel = UIWindowLevelAlert + 1;
            picker.ownedWindow.rootViewController = [[UINavigationController alloc] initWithRootViewController:picker];
            __weak PXPPicker *weakPicker = picker;
            picker.backgroundObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { [weakPicker cancel]; }];
            picker.disconnectObserver = [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidDisconnectNotification object:scene queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { [weakPicker cancel]; }];
            [picker.ownedWindow makeKeyAndVisible];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [weakPicker complete:nil error:PXPError(PXPAccountsTimedOut, @"Account selection timed out.")];
            });
        } @catch (NSException *e) {
            if (PXPPicking) [PXPPicking complete:nil error:PXPException(e)];
            else reply(nil, PXPException(e));
        }
    });
}

// SBApplicationProcessState is re-read, never cached as a truth value. Missing
// controller/app/state/selector is an error, not an assertion that the app died.
static BOOL PXPReadProcess(NSString *bundle, pid_t *pid, BOOL *running, NSError **error) {
    @try {
        id controller = PXPObject0(NSClassFromString(@"SBApplicationController"), @"sharedInstance");
        id app = PXPObject1(controller, @"applicationWithBundleIdentifier:", bundle);
        id state = PXPObject0(app, @"processState");
        PXPRequire(state, @"pid", @encode(int), @[]);
        *pid = ((int (*)(id, SEL))objc_msgSend)(state, NSSelectorFromString(@"pid"));
        *running = PXPBool0(state, @"isRunning");
        if (*pid < 0 || (*running != (*pid > 0))) {
            *error = PXPError(PXPAccountsInvalidData, @"Inconsistent processState.pid/isRunning.");
            return NO;
        }
        return YES;
    } @catch (NSException *e) { *error = PXPException(e); return NO; }
}
static BOOL PXPPIDExited(pid_t oldPID) {
    if (oldPID <= 0) return YES;
    // kill(..., 0) never terminates. EPERM, EINTR and every unknown error are NOT exit.
    errno = 0;
    return kill(oldPID, 0) == -1 && errno == ESRCH;
}
static BOOL PXPTerminationSignature(id service, BOOL *wide) {
    if (PXPSignature(service, PXPTerminateSelector, "v", @[@"@", @"q", @"B", @"@", @"@?"])) {
        *wide = YES; return YES;
    }
    if (PXPSignature(service, PXPTerminateSelector, "v", @[@"@", @"i", @"B", @"@", @"@?"])) {
        *wide = NO; return YES;
    }
    return NO; // No BOOL-as-char, arbitrary integer width or untyped completion.
}

@interface PXPPreparation : NSObject
@property(nonatomic, copy) NSString *bundle;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) BOOL (^isCurrent)(void);
@property(nonatomic, copy) void (^completion)(BOOL, NSError *);
@property(nonatomic, strong) id manager;
@property(nonatomic, strong) id service;
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic) pid_t oldPID;
@property(nonatomic) BOOL wideReason;
@property(nonatomic) BOOL done;
@property(nonatomic) BOOL terminating;
@property(nonatomic) BOOL authPending;
@property(nonatomic) BOOL authStarted;
@property(nonatomic) NSTimeInterval deadline;
- (void)finish:(BOOL)success error:(NSError *)error;
- (void)tick;
- (void)authenticate;
- (void)start;
@end
@implementation PXPPreparation
- (void)releaseIfQuiescent {
    // Identity guard prevents an old completion from releasing a newer request.
    if (!self.done || self.authPending || self.terminating) return;
    if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
    if (PXPPreparing == self) PXPPreparing = nil;
    self.manager = nil;
    self.service = nil;
}
- (void)finish:(BOOL)success error:(NSError *)error {
    NSAssert(NSThread.isMainThread, @"main only");
    if (self.done) return;
    self.done = YES;
    void (^callback)(BOOL, NSError *) = self.completion;
    self.completion = nil;
    self.isCurrent = nil;
    [self releaseIfQuiescent];
    // Public entry already dispatched asynchronously to main. Deliver now:
    // a second dispatch would leave a stale-success window after isCurrent.
    // done/completion=nil above also prevent re-completion if client throws.
    if (callback) callback(success, error);
}
- (BOOL)current {
    if (self.done || PXPPreparing != self) return NO;
    BOOL value = NO;
    @try { value = self.isCurrent && self.isCurrent(); }
    @catch (__unused NSException *e) { value = NO; }
    if (!value) [self finish:NO error:PXPError(PXPAccountsCancelled, @"Stale or cancelled account transaction.")];
    return value;
}
- (void)armTimer {
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), 100 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    __weak PXPPreparation *weakSelf = self;
    dispatch_source_set_event_handler(self.timer, ^{ [weakSelf tick]; });
    dispatch_resume(self.timer);
}
- (void)tick {
    NSAssert(NSThread.isMainThread, @"main only");
    if (PXPPreparing != self) return;
    if (!self.done) {
        if (![self current]) { /* Drain in-flight termination below; never start auth. */ }
        else if (NSProcessInfo.processInfo.systemUptime >= self.deadline)
            [self finish:NO error:PXPError(PXPAccountsTimedOut, @"Account preparation timed out; no application may be launched.")];
    }
    if (self.terminating) {
        NSError *error = nil;
        pid_t pid = 0;
        BOOL running = NO;
        if (!PXPReadProcess(self.bundle, &pid, &running, &error)) {
            if (!self.done) [self finish:NO error:error];
            return; // Cannot prove quiescence: keep the lock, do not guess.
        }
        if (pid != 0 && pid != self.oldPID) {
            if (!self.done) [self finish:NO error:PXPError(PXPAccountsTerminationFailed, @"Application respawned while terminating the old PID.")];
            return;
        }
        // Poll actual state AND the old kernel PID, not elapsed delay or request ACK.
        if (!running && pid == 0 && PXPPIDExited(self.oldPID)) {
            self.terminating = NO;
            if (self.done) [self releaseIfQuiescent];
            else [self authenticate];
        }
    } else if (self.done) {
        [self releaseIfQuiescent];
        // Authentication cannot be cancelled through the evidenced API. If it
        // never calls back, keep the global busy lock indefinitely (fail closed).
        if (self.authPending && self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
    }
}
- (void)authenticationReturned:(BOOL)success {
    NSAssert(NSThread.isMainThread, @"main only");
    if (!self.authPending || PXPPreparing != self) return; // Duplicate/old callback.
    self.authPending = NO;
    if (self.done) { [self releaseIfQuiescent]; return; }
    if (![self current]) return;
    if (NSProcessInfo.processInfo.systemUptime >= self.deadline) {
        [self finish:NO error:PXPError(PXPAccountsTimedOut, @"Authentication returned after the transaction deadline.")]; return;
    }
    if (!success) { [self finish:NO error:PXPError(PXPAccountsCancelled, @"Crane authentication or account switch was declined.")]; return; }
    @try {
        NSError *error = nil;
        NSArray *rows = PXPContainers(self.manager, self.bundle, &error);
        if (!rows || !PXPContains(rows, self.identifier) ||
            ![PXPActive(self.manager, self.bundle) isEqualToString:self.identifier]) {
            [self finish:NO error:error ?: PXPError(PXPAccountsVerificationFailed, @"Crane active preference did not match the selected account.")]; return;
        }
        pid_t pid = 0;
        BOOL running = NO;
        if (!PXPReadProcess(self.bundle, &pid, &running, &error)) { [self finish:NO error:error]; return; }
        if (running || pid != 0 || !PXPPIDExited(self.oldPID)) {
            [self finish:NO error:PXPError(PXPAccountsVerificationFailed, @"A process exists before the caller's fresh launch.")]; return;
        }
        if (![self current]) return;
        [self finish:YES error:nil];
    } @catch (NSException *e) { [self finish:NO error:PXPException(e)]; }
}
- (void)authenticate {
    if (self.authStarted || ![self current]) return;
    if (NSProcessInfo.processInfo.systemUptime >= self.deadline) {
        [self finish:NO error:PXPError(PXPAccountsTimedOut, @"Preparation deadline expired before authentication.")]; return;
    }
    @try {
        NSError *error = nil;
        pid_t pid = 0;
        BOOL running = NO;
        if (!PXPReadProcess(self.bundle, &pid, &running, &error)) { [self finish:NO error:error]; return; }
        if (running || pid != 0 || !PXPPIDExited(self.oldPID)) {
            [self finish:NO error:PXPError(PXPAccountsTerminationFailed, @"Old process has not exited, or a process respawned.")]; return;
        }
        // Revalidate after asynchronous termination. Same active preference is
        // NOT a bypass for terminating an old process or for normal biometrics.
        NSArray *rows = PXPContainers(self.manager, self.bundle, &error);
        if (!rows || !PXPContains(rows, self.identifier)) {
            [self finish:NO error:error ?: PXPError(PXPAccountsInvalidData, @"Selected account no longer exists.")]; return;
        }
        PXPRequire(self.manager, PXPBioSelector, "v", @[@"@", @"@", @"@?"]);
        if (![self current]) return;
        self.authStarted = YES;
        self.authPending = YES;
        // Evidence-backed v12@?0B8. The callback only submits work to main;
        // it never mutates transaction state on Crane's arbitrary callback queue.
        void (^handler)(BOOL) = ^(BOOL success) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self authenticationReturned:success]; });
        };
        ((void (*)(id, SEL, id, id, void (^)(BOOL)))objc_msgSend)(self.manager,
            NSSelectorFromString(PXPBioSelector), self.identifier, self.bundle, [handler copy]);
    } @catch (NSException *e) {
        // A throwing setter may already have retained its handler. Never unlock
        // authPending on an exception; only the real callback can drain it.
        [self finish:NO error:PXPException(e)];
    }
}
- (void)start {
    if (![self current]) return;
    @try {
        self.manager = PXPManager();
        NSError *error = nil;
        NSArray *rows = PXPContainers(self.manager, self.bundle, &error);
        if (!rows || !PXPContains(rows, self.identifier)) {
            [self finish:NO error:error ?: PXPError(PXPAccountsInvalidArgument, @"Unknown container identifier.")]; return;
        }
        PXPRequire(self.manager, PXPBioSelector, "v", @[@"@", @"@", @"@?"]);
        NSString *active = PXPActive(self.manager, self.bundle);
        if (!active || !PXPContains(rows, active)) {
            [self finish:NO error:PXPError(PXPAccountsInvalidData, @"Invalid or unknown active container identifier.")]; return;
        }
        pid_t pid = 0;
        BOOL running = NO;
        if (!PXPReadProcess(self.bundle, &pid, &running, &error)) { [self finish:NO error:error]; return; }
        self.oldPID = pid;
        self.deadline = NSProcessInfo.processInfo.systemUptime + 45.0;
        if (running) {
            self.service = PXPObject0(NSClassFromString(@"FBSystemService"), @"sharedInstance");
            BOOL wide = NO;
            if (!PXPTerminationSignature(self.service, &wide)) {
                [self finish:NO error:PXPError(PXPAccountsUnsupportedABI, @"Unrecognized FBSystemService termination signature.")]; return;
            }
            self.wideReason = wide;
        }
        [self armTimer];
        if (![self current]) return;
        if (!running) { [self authenticate]; return; }
        // The caller must already have closed its old host/scene. Termination
        // request ACK is intentionally ignored; only true PID exit advances.
        self.terminating = YES;
        void (^ack)(void) = ^{}; // descriptor 985a8: v8@?0, not an exit signal.
        if (self.wideReason) {
            ((void (*)(id, SEL, id, long long, BOOL, id, void (^)(void)))objc_msgSend)(self.service,
                NSSelectorFromString(PXPTerminateSelector), self.bundle, 1LL, YES, @"ParallelXPayment account switch", ack);
        } else {
            ((void (*)(id, SEL, id, int, BOOL, id, void (^)(void)))objc_msgSend)(self.service,
                NSSelectorFromString(PXPTerminateSelector), self.bundle, 1, YES, @"ParallelXPayment account switch", ack);
        }
    } @catch (NSException *e) { [self finish:NO error:PXPException(e)]; }
}
@end

void PXPPrepareAccount(NSString *bundle, NSString *containerID, BOOL (^isCurrent)(void), void (^completion)(BOOL, NSError *)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!completion) return;
        if (!PXPString(bundle) || !PXPString(containerID) || !isCurrent) {
            completion(NO, PXPError(PXPAccountsInvalidArgument, @"Bundle, explicit account and isCurrent are required.")); return;
        }
        if (PXPPreparing || PXPPicking) {
            completion(NO, PXPError(PXPAccountsBusy, @"An account transaction or outstanding Crane authentication is busy.")); return;
        }
        PXPPreparation *request = [PXPPreparation new];
        request.bundle = [bundle copy];
        request.identifier = [containerID copy];
        request.isCurrent = [isCurrent copy];
        request.completion = [completion copy];
        PXPPreparing = request;
        [request start];
    });
}

void PXPVerifyRunningAccount(NSString *bundle,NSString *containerID,BOOL (^isCurrent)(void),void (^completion)(BOOL,NSError *)) {
    dispatch_async(dispatch_get_main_queue(),^{
        if(!completion) return;
        if(!isCurrent || !isCurrent()) { completion(NO,PXPError(PXPAccountsCancelled,@"Payment route expired before process verification")); return; }
        NSError *error=nil; pid_t pid=0; BOOL running=NO;
        if(!PXPReadProcess(bundle,&pid,&running,&error) || !running || pid<=0) {
            completion(NO,error ?: PXPError(PXPAccountsVerificationFailed,@"Payment process is not running")); return;
        }
        @try {
            id manager=PXPManager();
            // Device CraneSupport calls the same CRHGlobalServiceProtocol method.
            // Protocol method: v28@0:8i16@?20. Nested reply descriptor:
            // 0x20d30 -> 0x1c4fe: v20@?0@\"NSString\"8i16.
            Protocol *protocol=objc_getProtocol("CRHGlobalServiceProtocol");
            SEL query=NSSelectorFromString(@"fetchActiveContainerIDForProcessWithPid:reply:");
            if(!protocol) { completion(NO,PXPError(PXPAccountsUnavailable,@"Crane process query protocol is not loaded")); return; }
            struct objc_method_description md=protocol_getMethodDescription(protocol,query,YES,YES);
            NSMethodSignature *sig=md.types ? [NSMethodSignature signatureWithObjCTypes:md.types] : nil;
            if(!sig || sig.numberOfArguments!=4 || strcmp(sig.methodReturnType,"v") ||
               strcmp([sig getArgumentTypeAtIndex:2],@encode(int)) || strcmp([sig getArgumentTypeAtIndex:3],"@?")) {
                completion(NO,PXPError(PXPAccountsUnsupportedABI,@"Unsupported Crane process query ABI")); return;
            }
            id proxy=PXPObject0(manager,@"cranehelperdGlobalAsyncRemoteObjectProxy");
            if(!proxy || ![proxy respondsToSelector:query]) {
                completion(NO,PXPError(PXPAccountsUnavailable,@"Crane process verification service unavailable")); return;
            }
            __block BOOL replied=NO;
            void (^reply)(BOOL,NSError *)=^(BOOL ok,NSError *failure){
                if(replied) return; replied=YES;
                completion(ok,failure);
            };
            void (^handler)(NSString *,int)=[^(NSString *actual,int auxiliary){
                // Actual cranehelperd 0x10000483c..86c: auxiliary=1 means
                // Crane injection missing for the queried PID; it is not a PID.
                dispatch_async(dispatch_get_main_queue(),^{
                    if(replied) return;
                    if(!isCurrent()) { reply(NO,PXPError(PXPAccountsCancelled,@"Payment route expired during process verification")); return; }
                    NSError *readError=nil; pid_t currentPID=0; BOOL alive=NO;
                    BOOL same=PXPReadProcess(bundle,&currentPID,&alive,&readError) && alive && currentPID==pid;
                    BOOL matches=same && auxiliary==0 && PXPString(actual) && [actual isEqualToString:containerID] && PXPAccountStillMatches(bundle,containerID);
                    reply(matches,matches ? nil : (readError ?: PXPError(PXPAccountsVerificationFailed,@"Running process account does not match selected payment account")));
                });
            } copy];
            ((void(*)(id,SEL,int,void(^)(NSString *,int)))objc_msgSend)(proxy,query,(int)pid,handler);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
                reply(NO,PXPError(PXPAccountsTimedOut,@"Crane process verification timed out"));
            });
        } @catch(NSException *exception) { completion(NO,PXPException(exception)); }
    });
}

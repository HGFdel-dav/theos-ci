// TWPath.h — shared jbroot path resolution (RootHide / rootless compatible)
// Used by both the SpringBoard tweak and the standalone Settings bundle.
//
// Verified on the target device (iOS 15.5 / RootHide):
//   /Library  -> /var/containers/Bundle/Application/.jbroot-703BE1466AE884EA/Library
//   the same jbroot is also reachable as
//   /var/mobile/Containers/Shared/AppGroup/.jbroot-703BE1466AE884EA/
// so BOTH bases must be scanned.
#import <Foundation/Foundation.h>
#import <dlfcn.h>

// Deliberately not dispatch_once: RootHide roots can rotate during this process.
static inline NSArray<NSString *> *TWJBRootCandidates(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *roots = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSArray *bases = @[
        @"/var/containers/Bundle/Application",
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/var/mobile/Containers/Bundle/Application",
    ];
    for (NSString *base in bases) {
        for (NSString *name in [fm contentsOfDirectoryAtPath:base error:nil]) {
            if (![name hasPrefix:@".jbroot-"]) continue;
            NSString *path = [base stringByAppendingPathComponent:name];
            NSString *key = path.stringByResolvingSymlinksInPath ?: path;
            if ([seen containsObject:key]) continue;
            BOOL directory = NO;
            if ([fm fileExistsAtPath:path isDirectory:&directory] && directory) {
                [seen addObject:key];
                [roots addObject:path];
            }
        }
    }
    BOOL directory = NO;
    if ([fm fileExistsAtPath:@"/var/jb" isDirectory:&directory] && directory) [roots addObject:@"/var/jb"];
    return roots;
}

// Pick the root that actually contains this package's files. The dylib wins;
// in the Preferences process (no dylib injected) the bundle path wins instead,
// so both processes resolve to the same directory.
static inline NSString *TWJBRootPath(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    Dl_info image = {0};
    dladdr((const void *)&TWJBRootPath, &image);
    NSString *own = image.dli_fname ? [[NSString stringWithUTF8String:image.dli_fname] stringByResolvingSymlinksInPath] : @"";
    NSString *best = nil; NSInteger bestScore = -1; NSTimeInterval bestTime = -1;
    for (NSString *root in TWJBRootCandidates()) {
        NSString *resolved = root.stringByResolvingSymlinksInPath;
        if (!resolved.length || [resolved isEqualToString:@"/"]) continue;
        NSString *ms = [root stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries/Twin.dylib"];
        NSString *usr = [root stringByAppendingPathComponent:@"usr/lib/Twin.dylib"];
        NSString *bundle = [root stringByAppendingPathComponent:@"Library/PreferenceBundles/TwinPrefs.bundle"];
        BOOL hasMS = [fm fileExistsAtPath:ms], hasUsr = [fm fileExistsAtPath:usr];
        BOOL hasBundle = [fm fileExistsAtPath:bundle];
        NSInteger score = hasMS ? 2000 : (hasUsr ? 1000 : 0);
        if (hasBundle) score += 500;
        if (own.length) {
            NSString *prefix = [resolved stringByAppendingString:@"/"];
            if ([own hasPrefix:prefix]) score += 10000;
        }
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"Library/MobileSubstrate"]]) score += 20;
        else if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"usr/lib"]]) score += 10;
        if (!score) continue;
        NSString *stampPath = hasMS ? ms : (hasUsr ? usr : (hasBundle ? bundle : root));
        NSTimeInterval stamp = [[[fm attributesOfItemAtPath:stampPath error:nil] fileModificationDate] timeIntervalSince1970];
        if (score > bestScore || (score == bestScore && (stamp > bestTime || (stamp == bestTime && [root compare:best] == NSOrderedAscending)))) {
            best = root; bestScore = score; bestTime = stamp;
        }
    }
    return best ?: @"";
}

// The real /var/mobile/Library/Preferences must never hold Twin preferences.
static inline BOOL TWPrefsPathIsSafe(NSString *path) {
    if (![path.lastPathComponent isEqualToString:@"com.niubiprass.twin.plist"]) return NO;
    NSString *resolved = path.stringByResolvingSymlinksInPath;
    for (NSString *real in @[@"/var/mobile/Library/Preferences", @"/private/var/mobile/Library/Preferences"]) {
        if ([resolved hasPrefix:[real stringByAppendingString:@"/"]]) return NO;
    }
    for (NSString *root in TWJBRootCandidates()) {
        NSString *base = root.stringByResolvingSymlinksInPath;
        if (base.length > 1 && [resolved hasPrefix:[base stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

static inline NSString *TWPrefsFilePath(void) {
    NSString *base = TWJBRootPath();
    if (!base.length) return nil;
    NSString *path = [base stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.niubiprass.twin.plist"];
    return TWPrefsPathIsSafe(path) ? path : nil;
}

#define TWPrefsChangedNotification "com.niubiprass.twin/preferences-changed"

#define TWKeyEnabled          @"TWEnabled"
#define TWKeyArcEnabled       @"TWArcEnabled"
#define TWKeyArcSide          @"TWArcSide"          // 0 left, 1 right
#define TWKeyArcTriggerWidth  @"TWArcTriggerWidth"  // points
#define TWKeyArcItemCount     @"TWArcItemCount"     // icons per menu
#define TWKeyArcRadius        @"TWArcRadius"        // points
#define TWKeyArcSound         @"TWArcSoundEnabled"
#define TWKeyArcHaptic        @"TWArcHapticEnabled"   // 震动反馈（0.5.0）
#define TWKeyArcIconSource    @"TWArcIconSource"      // 0=最近应用 1=自选应用（0.5.0）
#define TWKeyArcLongPressMode @"TWArcLongPressMode"   // 0=分身 1=小窗 2=无（0.5.0）
#define TWKeyRememberAppsScope  @"TWRememberAppsScope"   // 0=全部 1=指定（0.5.0）
#define TWKeyRememberAutoRestore @"TWRememberAutoRestore" // 自动恢复到上次尺寸（0.5.0）
#define TWKeyRememberShowButton  @"TWRememberShowButton"  // 显示「恢复上次尺寸」按钮（0.5.0）
// 弧形覆盖窗口的层级优先级（Arc-X 同名概念）：0～2200，默认 46。
// 生效层级 = UIWindowLevelAlert - 2 + 该值（即 1998..4198）。
#define TWKeyArcWindowPriority @"TWArcWindowPriority"
#define TWArcPriorityDefault  46
#define TWArcPriorityMax      2200
#define TWKeyCraneEnabled     @"TWCraneEnabled"
#define TWKeyCraneApps        @"TWCraneApps"        // NSDictionary { bundleID : containerID }
#define TWKeyRememberSize     @"TWRememberSize"     // BOOL, default NO
#define TWKeyRememberFrames   @"TWRememberFrames"   // 旧格式（只读迁移）: dict { bundleID : {x,y,w,h} }

// ── 0.4.0：唤醒方式二选一 ──────────────────────────────────────────────
// 0 = Arc 角落唤醒（Twin 新增，从屏幕角落起手；默认）
// 1 = ParallelX 原生边缘手柄（Twin 不接管手势，原样保留）
#define TWKeyWakeMode         @"TWWakeMode"
#define TWWakeModeCorner      0
#define TWWakeModeHandle      1
// 角落触发区：位掩码 1=右下 2=左下 4=左上 8=右上（默认 3 = 下边两角）
#define TWKeyArcCorners       @"TWArcCorners"
#define TWKeyArcCornerSize    @"TWArcCornerSize"    // 触发区边长(pt)，默认 64
// 打开方式：0 = 分屏启动（默认） 1 = 全屏启动
#define TWKeyArcOpenMode      @"TWArcOpenMode"
#define TWKeySideOpenMode     @"TWSideOpenMode"
// 分身：Arc 里显示哪些应用（有序 bundleID）＋ 每个容器的显示/角标
#define TWKeyCraneAppList     @"TWCraneAppList"     // NSArray<NSString *>
#define TWKeyCraneContainers  @"TWCraneContainers"  // NSArray<NSDictionary *>
// 记忆：总开关 + 形态快照 { "bundleID|containerID" : @{p,l,docked,side,updated} }
// 记忆模块要靠这个知道"这次打开的是哪个容器"：ParallelX 的面板窗口出现时
// 只带 bundleID，容器信息只能由 Twin 在打开前记一笔。
#define TWKeyLastLaunch       @"TWLastLaunch"       // @{bundleID, containerID, at}
#define TWKeyRememberStates   @"TWRememberStates"
// 判定"缩小/贴边"的阈值：面板宽度 < 屏幕宽度 * 该比例
#define TWRememberDockRatio   0.55
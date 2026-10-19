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

// 0.9.8：拼路径时不要 `root + "/" + sub`——当 root 就是 "/" 时会长出 "//var/..."。
static inline NSString *TWJoinPath(NSString *root, NSString *sub) {
    if (!root.length || [root isEqualToString:@"/"]) return [@"/" stringByAppendingPathComponent:sub];
    return [root stringByAppendingPathComponent:sub];
}

// 0.9.8：从"自己所在的这份二进制"倒推根目录，这比扫描目录可靠得多。
//   SpringBoard：Twin.dylib 在 <root>/Library/MobileSubstrate/DynamicLibraries/
//   设置进程  ：TwinPrefs 在 <root>/Library/PreferenceBundles/TwinPrefs.bundle/
// 两种情况都只要砍掉 "/Library/" 及其之后的部分。
// 关键背景：本机的 RootHide 把 .jbroot-xxx 和 /var/jb 都做成了指向 "/" 的符号链接
//（readlink = "//"），所以倒推出来的根就可能正好是 "/"——这必须被当作合法结果，
// 不能像旧代码那样一律按"写到真实目录"拒掉。
static inline NSArray<NSString *> *TWJBRootSelfDerived(void) {
    NSMutableArray *roots = [NSMutableArray array];
    Dl_info info = {0};
    if (dladdr((const void *)&TWJBRootSelfDerived, &info) && info.dli_fname) {
        NSString *own = [[NSString stringWithUTF8String:info.dli_fname] stringByResolvingSymlinksInPath];
        NSRange cut = [own rangeOfString:@"/Library/"];
        if (cut.location != NSNotFound) {
            NSString *root = [own substringToIndex:cut.location];
            [roots addObject:root.length ? root : @"/"];
        }
    }
    return roots;
}

// Deliberately not dispatch_once: RootHide roots can rotate during this process.
static inline NSArray<NSString *> *TWJBRootCandidates(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *roots = [NSMutableArray arrayWithArray:TWJBRootSelfDerived()];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *root in roots) [seen addObject:(root.stringByResolvingSymlinksInPath ?: root)];
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
// 0.9.8：不再把 "→ /" 的根当非法。本机 RootHide 的 .jbroot-*/var/jb 都是指向
// "/" 的符号链接，排掉它们就等于排掉了全部候选，偏好路径永远是 nil。
static inline NSString *TWJBRootPath(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    Dl_info image = {0};
    dladdr((const void *)&TWJBRootPath, &image);
    NSString *own = image.dli_fname ? [[NSString stringWithUTF8String:image.dli_fname] stringByResolvingSymlinksInPath] : @"";
    NSString *best = nil; NSInteger bestScore = -1; NSTimeInterval bestTime = -1;
    for (NSString *root in TWJBRootCandidates()) {
        NSString *resolved = root.stringByResolvingSymlinksInPath ?: root;
        if (!resolved.length) resolved = root;
        NSString *ms = TWJoinPath(root, @"Library/MobileSubstrate/DynamicLibraries/Twin.dylib");
        NSString *usr = TWJoinPath(root, @"usr/lib/Twin.dylib");
        NSString *bundle = TWJoinPath(root, @"Library/PreferenceBundles/TwinPrefs.bundle");
        BOOL hasMS = [fm fileExistsAtPath:ms], hasUsr = [fm fileExistsAtPath:usr];
        BOOL hasBundle = [fm fileExistsAtPath:bundle];
        NSInteger score = hasMS ? 2000 : (hasUsr ? 1000 : 0);
        if (hasBundle) score += 500;
        if (own.length) {
            NSString *prefix = [resolved isEqualToString:@"/"] ? @"/" : [resolved stringByAppendingString:@"/"];
            if ([own hasPrefix:prefix]) score += 10000;
        }
        if ([fm fileExistsAtPath:TWJoinPath(root, @"Library/MobileSubstrate")]) score += 20;
        else if ([fm fileExistsAtPath:TWJoinPath(root, @"usr/lib")]) score += 10;
        if (!score) continue;
        NSString *stampPath = hasMS ? ms : (hasUsr ? usr : (hasBundle ? bundle : root));
        NSTimeInterval stamp = [[[fm attributesOfItemAtPath:stampPath error:nil] fileModificationDate] timeIntervalSince1970];
        if (score > bestScore || (score == bestScore && (stamp > bestTime || (stamp == bestTime && [root compare:best] == NSOrderedAscending)))) {
            best = root; bestScore = score; bestTime = stamp;
        }
    }
    return best ?: @"";
}

// ── 偏好落点（0.9.8 重做）──────────────────────────────────────────────
// 旧实现（≤0.9.7）要求偏好必须落在某个 .jbroot-* 内部，否则判"不安全"直接
// 拒绝读写。而本机 RootHide 把 .jbroot-xxx、/var/jb 都做成了指向 "/" 的
// 符号链接（readlink 结果"//"），解析出来永远是真实路径 → 每一次读写都被
// 拒掉 → 面板改完不保存、SpringBoard 永远读默认值（"设置全都不生效"）。
// 现在：落点固定为 <root>/var/mobile/Library/Twin/prefs.plist，
// 不放 Preferences 目录（越狱检测常扫那里），也不再对"真实路径"做封锁。
static inline NSArray<NSString *> *TWPrefsDirectoryCandidates(void) {
    NSMutableArray *dirs = [NSMutableArray array];
    for (NSString *root in TWJBRootCandidates()) {
        NSString *dir = TWJoinPath(root, @"var/mobile/Library/Twin");
        if (dir.length && ![dirs containsObject:dir]) [dirs addObject:dir];
    }
    if (![dirs containsObject:@"/var/mobile/Library/Twin"]) [dirs addObject:@"/var/mobile/Library/Twin"];
    return dirs;
}

static inline BOOL TWPrefsPathIsSafe(NSString *path) {
    NSString *name = path.lastPathComponent;
    return [name isEqualToString:@"prefs.plist"] || [name isEqualToString:@"com.niubiprass.twin.plist"];
}

// 现有文件里取最新的那份；都不存在就用第一个候选（写的时候会建目录）。
static inline NSString *TWPrefsFilePath(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *best = nil; NSTimeInterval bestTime = -1;
    for (NSString *dir in TWPrefsDirectoryCandidates()) {
        NSString *path = [dir stringByAppendingPathComponent:@"prefs.plist"];
        if (![fm fileExistsAtPath:path]) continue;
        NSTimeInterval stamp = [[[fm attributesOfItemAtPath:path error:nil] fileModificationDate] timeIntervalSince1970];
        if (stamp >= bestTime) { best = path; bestTime = stamp; }
    }
    if (best.length) return best;
    NSString *first = TWPrefsDirectoryCandidates().firstObject;
    return first.length ? [first stringByAppendingPathComponent:@"prefs.plist"] : nil;
}

// 旧版本留下来的偏好（迁移用）：旧位置在 Preferences 目录，迁移成功后要删掉。
static inline NSArray<NSString *> *TWLegacyPrefsFiles(void) {
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *root in TWJBRootCandidates()) {
        NSString *p = TWJoinPath(root, @"var/mobile/Library/Preferences/com.niubiprass.twin.plist");
        if (p.length && ![files containsObject:p]) [files addObject:p];
    }
    for (NSString *p in @[@"/var/mobile/Library/Preferences/com.niubiprass.twin.plist",
                          @"/var/jb/var/mobile/Library/Preferences/com.niubiprass.twin.plist"]) {
        if (![files containsObject:p]) [files addObject:p];
    }
    return files;
}

#define TWPrefsChangedNotification "com.niubiprass.twin/preferences-changed"

#define TWKeyEnabled          @"TWEnabled"
#define TWKeyArcEnabled       @"TWArcEnabled"
#define TWKeyArcSide          @"TWArcSide"          // 0 left, 1 right
#define TWKeyArcUsePXPanel    @"TWArcUsePXPanel"     // 1 = 用 ParallelX 自己的面板（默认）
#define TWKeyArcIconSize     @"TWArcIconSize"      // 图标直径(pt)，默认 44
#define TWKeyArcFirstRowCount @"TWArcFirstRowCount" // 第一环图标数，默认 5
#define TWKeyArcRingGap      @"TWArcRingGap"       // 环间距(pt)，默认 10
#define TWKeyArcTriggerWidth  @"TWArcTriggerWidth"  // points
#define TWKeyArcItemCount     @"TWArcItemCount"     // icons per menu
#define TWKeyArcRadius        @"TWArcRadius"        // points

// ── 0.9.7：照抄 ScreenCore TriggerSettings 的全部 arc 参数 ──────────────
#define TWKeyArcMirror          @"TWArcMirror"              // 对称镜像，默认 NO
#define TWKeyArcOffsetX         @"TWArcOffsetX"             // 圆心偏移 X，0–100，默认 0
#define TWKeyArcOffsetY         @"TWArcOffsetY"             // 圆心偏移 Y，0–100，默认 0
#define TWKeyArcOffsetDistance  @"TWArcOffsetDistance"      // 偏移距离，0–200，默认 0
#define TWKeyArcLandscapeOffset @"TWArcLandscapeOffset"     // 横屏水平偏移，0–200，默认 0
#define TWKeyArcMenuScale       @"TWArcMenuScalePercent"    // 菜单整体缩放，50–150，默认 100
#define TWKeyArcAppIconScale    @"TWArcAppIconScalePercent" // 应用图标缩放，10–100，默认 70
#define TWKeyArcIconBgAlpha     @"TWArcIconBgAlphaPercent"  // 图标底色透明度，0–100，默认 100
#define TWKeyArcTriggerMode     @"TWArcTriggerMode"         // 0=扇形(默认) 1=矩形
#define TWKeyArcRectLength      @"TWArcRectLength"          // 矩形长度，1–150，默认 40
#define TWKeyArcRectHeight      @"TWArcRectHeight"          // 矩形高度，1–150，默认 40
#define TWKeyArcRectCorner      @"TWArcRectCorner"          // 矩形圆角，0–150，默认 12
#define TWKeyArcSpringEnabled   @"TWArcSpringEnabled"       // 弹性动画，默认 NO
#define TWKeyArcSpringDamping   @"TWArcSpringDamping"       // 弹性阻尼，0.5–1.0，默认 0.68
#define TWKeyArcSelectedIcon    @"TWArcSelectedIconEnabled" // 选中高亮，默认 YES
#define TWKeyArcBgEnabled       @"TWArcBackgroundEnabled"   // 菜单背景，默认 NO
#define TWKeyArcBgAlpha         @"TWArcBackgroundAlpha"     // 背景透明度，0.1–1.0，默认 0.3
#define TWKeyArcDebug           @"TWArcDebugMode"           // 调试模式，默认 NO
#define TWKeyArcHideCapture     @"TWArcHideFromCapture"     // 截图时隐藏，默认 NO
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
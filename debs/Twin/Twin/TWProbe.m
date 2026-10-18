// TWProbe.m
// 只做 introspection：列类、列方法、查 respondsToSelector、扫窗口层级里的类名。
// 不调用任何私有方法、不改任何状态，全部 @try 兜底。
#import "TWProbe.h"
#import "TWPath.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import <string.h>

static NSString *TWProbeFilePath = nil;

static NSArray<NSString *> *TWProbeMethods(Class cls, BOOL classMethods) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (!cls) return names;
    Class target = classMethods ? object_getClass(cls) : cls;
    if (!target) return names;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(target, &count);
    if (!methods) return names;
    for (unsigned int i = 0; i < count; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        if (name && *name) {
            NSString *string = @(name);
            if (string.length && ![names containsObject:string]) [names addObject:string];
        }
    }
    free(methods);
    [names sortUsingSelector:@selector(compare:)];
    return names;
}

// 值得关注的候选入口（从 ParallelX 的选择子表里挑出来的，见分析记录）。
static NSArray<NSString *> *TWProbeCandidates(void) {
    return @[@"applicationActivated:", @"openFullscreenApplication:", @"externalOpenApplication:",
             @"openApplication:inView:keyboardOverlay:completion:", @"prepareWindowForBundleID:wasFullscreen:completion:",
             @"dragHandle:", @"refreshHandleSettings", @"refreshDockSettings", @"dockTapped:", @"dockSwiped:",
             @"dockIconDragged:", @"restoreDockTapped:", @"showSplitAppIdentity", @"glowPathRail",
             @"presentedStashed", @"closeForFullscreen", @"fullscreenTapped", @"presentViewController:animated:completion:",
             @"togglePanel", @"showPanel", @"presentPanel", @"activatePanel", @"presentRail", @"showRail"];
}

// 扫窗口层级里像手柄/边缘条/停靠栏的视图，并记录它们能响应哪些手势回调。
static NSArray<NSDictionary *> *TWProbeViews(void) {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSArray<NSString *> *keywords = @[@"handle", @"rail", @"dock", @"panel", @"glide", @"edge", @"floating", @"stash"];
    NSMutableArray *queue = [NSMutableArray array];
    for (UIWindow *window in [UIApplication sharedApplication].windows) [queue addObject:window];
    NSInteger visited = 0;
    while (queue.count && visited < 4000) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        NSString *className = NSStringFromClass(view.class);
        if (!className.length) continue;
        NSString *lower = className.lowercaseString;
        BOOL interesting = NO;
        for (NSString *keyword in keywords) if ([lower containsString:keyword]) { interesting = YES; break; }
        if (interesting && ![seen containsObject:className]) {
            [seen addObject:className];
            NSMutableArray<NSString *> *responds = [NSMutableArray array];
            for (NSString *selectorName in @[@"dragHandle:", @"dockTapped:", @"dockSwiped:", @"dockIconDragged:",
                                             @"refreshHandleSettings", @"refreshDockSettings", @"restoreDockTapped:"]) {
                if ([view respondsToSelector:NSSelectorFromString(selectorName)]) [responds addObject:selectorName];
            }
            CGRect frame = view.frame;
            [result addObject:@{@"class": className,
                                @"frame": @[@(round(frame.origin.x)), @(round(frame.origin.y)),
                                            @(round(frame.size.width)), @(round(frame.size.height))],
                                @"hidden": @(view.hidden),
                                @"alpha": @(round(view.alpha * 100) / 100.0),
                                @"responds": responds}];
        }
        if (queue.count + visited < 4000) {
            for (UIView *subview in view.subviews) [queue addObject:subview];
        }
    }
    return result;
}

static NSString *TWProbeWritePath(void) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *root = TWJBRootPath();
    if (root.length) {
        NSString *directory = [root stringByAppendingPathComponent:@"var/mobile/Library/Application Support/Twin"];
        if ([manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) {
            NSString *path = [directory stringByAppendingPathComponent:@"parallelx-probe.json"];
            // 只写 jbroot 内的路径，绝不落真实 /var/mobile/Library/Preferences。
            if ([path hasPrefix:root]) return path;
        }
    }
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"twin-parallelx-probe.json"];
}

NSString *TWProbeOutputPath(void) { return TWProbeFilePath; }

static NSDictionary *TWProbeSnapshot(void) {
    NSMutableDictionary *report = [NSMutableDictionary dictionary];
    report[@"twinVersion"] = @"0.4.0";
    report[@"generatedAt"] = [NSDate date].description ?: @"";
    report[@"systemVersion"] = [UIDevice currentDevice].systemVersion ?: @"";
    report[@"model"] = [UIDevice currentDevice].model ?: @"";

    // 1) PXPanelEntry 的对外面（Swift 类只有 @objc 成员会出现在这里）
    Class entryClass = NSClassFromString(@"PXPanelEntry");
    report[@"pxPanelEntryExists"] = @(entryClass != nil);
    report[@"pxPanelEntryClassMethods"] = TWProbeMethods(entryClass, YES);
    report[@"pxPanelEntryInstanceMethods"] = TWProbeMethods(entryClass, NO);

    // 2) 候选入口能不能调（class / instance 两个方向分别测）
    NSMutableDictionary *candidates = [NSMutableDictionary dictionary];
    for (NSString *name in TWProbeCandidates()) {
        SEL selector = NSSelectorFromString(name);
        BOOL onClass = entryClass && [entryClass respondsToSelector:selector];
        BOOL onInstance = entryClass && [entryClass instancesRespondToSelector:selector];
        if (!onClass && !onInstance) continue;   // 只留能调的，文件小一点
        candidates[name] = @{@"classMethod": @(onClass), @"instanceMethod": @(onInstance)};
    }
    report[@"pxPanelEntryCandidates"] = candidates;

    // 3) 所有 PX* 类（看还有没有别的可用入口，比如停靠/小窗管理器）
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    NSMutableDictionary *pxClasses = [NSMutableDictionary dictionary];
    if (classes) {
        for (unsigned int i = 0; i < classCount && pxClasses.count < 120; i++) {
            Class cls = classes[i];
            const char *name = class_getName(cls);
            if (!name) continue;
            NSString *className = @(name);
            if (![className hasPrefix:@"PX"] && ![className hasPrefix:@"ParallelX"]) continue;
            pxClasses[className] = @{@"classMethods": TWProbeMethods(cls, YES),
                                     @"instanceMethods": TWProbeMethods(cls, NO)};
        }
        free(classes);
    }
    report[@"pxClasses"] = pxClasses;

    // 4) SpringBoard 里像"手柄/边缘条/停靠栏"的视图
    report[@"handleLikeViews"] = TWProbeViews();
    return report;
}

void TWProbeStart(void) {
    static BOOL started = NO;
    if (started) return;
    started = YES;
    // 等 ParallelX 把自己的窗口/手柄建好再扫。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            NSDictionary *snapshot = TWProbeSnapshot();
            NSData *json = [NSJSONSerialization dataWithJSONObject:snapshot
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:nil];
            if (!json) return;
            NSString *path = TWProbeWritePath();
            if (!path.length) return;
            if ([json writeToFile:path atomically:YES]) {
                TWProbeFilePath = [path copy];
                NSLog(@"[Twin] ParallelX 探针已写入 %@", path);
            }
        } @catch (__unused NSException *exception) {
            NSLog(@"[Twin] ParallelX 探针失败（已忽略，不影响手势）");
        }
    });
}
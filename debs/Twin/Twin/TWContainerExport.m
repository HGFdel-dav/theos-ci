// TWContainerExport.m
#import "TWContainerExport.h"
#import "TWPrefs.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/stat.h>

static NSString *TWEJBRoot(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *candidate in @[@"/var/jb", @"/"]) {
            if ([NSFileManager.defaultManager fileExistsAtPath:[candidate stringByAppendingPathComponent:@"usr/lib/libcrane.dylib"]]) {
                root = candidate; break;
            }
        }
    });
    return root;
}

static Class TWE_CraneManager(void) {
    static Class cls;
    static BOOL looked;
    if (!looked) {
        looked = YES;
        cls = NSClassFromString(@"CraneManager");
        if (!cls) {
            NSMutableArray<NSString *> *paths = [NSMutableArray array];
            NSString *root = TWEJBRoot();
            if (root.length) [paths addObject:[root stringByAppendingPathComponent:@"usr/lib/libcrane.dylib"]];
            [paths addObjectsFromArray:@[@"/var/jb/usr/lib/libcrane.dylib", @"/usr/lib/libcrane.dylib"]];
            for (NSString *path in paths) {
                if ([NSFileManager.defaultManager fileExistsAtPath:path] &&
                    dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
                    cls = NSClassFromString(@"CraneManager");
                    if (cls) break;
                }
            }
        }
    }
    return cls;
}

static id TWE_SharedManager(void) {
    static id mgr;
    static BOOL looked;
    if (!looked) {
        looked = YES;
        Class cls = TWE_CraneManager();
        if (cls) {
            SEL sel = NSSelectorFromString(@"sharedManager");
            if ([cls respondsToSelector:sel]) {
                mgr = ((id (*)(id, SEL))objc_msgSend)(cls, sel);
            }
        }
    }
    return mgr;
}

static id TWE_Call(NSString *selectorName, NSArray *args) {
    id target = TWE_SharedManager();
    if (!target) return nil;
    SEL sel = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:sel]) return nil;
    @try {
        if (args.count == 0) return ((id (*)(id, SEL))objc_msgSend)(target, sel);
        if (args.count == 1) return ((id (*)(id, SEL, id))objc_msgSend)(target, sel, args[0]);
        return ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)(target, sel, args[0], args[1], NO);
    } @catch (NSException *e) { return nil; }
}

static NSString *TWE_AppName(NSString *bundleID) {
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    SEL sel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxyCls && [proxyCls respondsToSelector:sel]) {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyCls, sel, bundleID);
        SEL nameSel = NSSelectorFromString(@"localizedName");
        if (proxy && [proxy respondsToSelector:nameSel]) {
            id name = ((id (*)(id, SEL))objc_msgSend)(proxy, nameSel);
            if ([name isKindOfClass:NSString.class] && [name length]) return name;
        }
    }
    return bundleID;
}

NSString *TWContainerExportPath(void) {
    return @"/var/mobile/Library/Twin/crane-containers.plist";
}

// 诊断日志：面板/用户可以直接看这个文件判断导出卡在哪一步。
static void TWELog(NSString *fmt, ...) {
    @try {
        va_list ap;
        va_start(ap, fmt);
        NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSString *path = @"/var/mobile/Library/Twin/export.log";
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                         dateStyle:NSDateFormatterNoStyle
                                                         timeStyle:NSDateFormatterMediumStyle];
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", stamp, line];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [entry writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (__unused NSException *e) { }
}

BOOL TWContainerExportNow(void) {
    if (![TWPrefs.shared boolForKey:TWKeyEnabled defaultValue:YES]) return NO;
    Class cls = TWE_CraneManager();
    if (!cls) {
        TWELog(@"CraneManager 不存在（Crane 未加载或类名不匹配）");
        return NO;   // Crane 还没加载：保留上次导出的缓存，不清空。
    }
    id mgr = TWE_SharedManager();
    if (!mgr) {
        TWELog(@"CraneManager 存在，但 +sharedManager 返回 nil");
        return NO;
    }
    if (![mgr respondsToSelector:NSSelectorFromString(@"identfiersOfApplicationsThatHaveNonDefaultContainers")]) {
        TWELog(@"sharedManager 不响应 identfiersOfApplicationsThatHaveNonDefaultContainers");
        return NO;
    }

    id apps = TWE_Call(@"identfiersOfApplicationsThatHaveNonDefaultContainers", @[]);
    if (![apps isKindOfClass:NSArray.class]) {
        TWELog(@"identfiersOfApplicationsThatHaveNonDefaultContainers 返回异常: %@", apps);
        return NO;
    }
    TWELog(@"CraneManager 可用，有非默认容器的应用数: %lu", (unsigned long)[(NSArray *)apps count]);

    NSMutableArray *exported = [NSMutableArray array];
    for (id item in (NSArray *)apps) {
        if (![item isKindOfClass:NSString.class] || ![item length]) continue;
        NSString *bundleID = item;
        id ids = TWE_Call(@"containerIdentifiersOfApplicationWithIdentifier:", @[bundleID]);
        // Crane 的默认容器 ID 就是 "DEFAULT"；空字符串不是合法 ID，
        // 之前导出成 "" 会让面板多出一行假"默认"，真默认反而被标成"分"。
        NSMutableArray *containers = [NSMutableArray arrayWithObject:@{ @"id": @"DEFAULT", @"name": @"默认" }];
        if ([ids isKindOfClass:NSArray.class]) {
            for (id cid in (NSArray *)ids) {
                if (![cid isKindOfClass:NSString.class] || ![cid length]) continue;
                if ([cid isEqualToString:@"DEFAULT"]) continue;
                id name = TWE_Call(@"displayNameForContainerWithIdentifier:ofApplicationWithIdentifier:shouldUseShortVersion:",
                                   @[cid, bundleID]);
                NSString *display = ([name isKindOfClass:NSString.class] && [name length]) ? name : cid;
                [containers addObject:@{ @"id": cid, @"name": display }];
            }
        }
        [exported addObject:@{ @"bundleID": bundleID,
                               @"name": TWE_AppName(bundleID),
                               @"containers": containers }];
    }

    NSDictionary *payload = @{ @"generatedAt": [NSDate date],
                               @"apps": exported };
    NSString *path = TWContainerExportPath();
    NSString *dir = [path stringByDeletingLastPathComponent];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL ok = [payload writeToFile:path atomically:YES];
    chmod(path.fileSystemRepresentation, 0644);
    TWELog(@"导出%@：%lu 个应用 -> %@", ok ? @"成功" : @"失败", (unsigned long)exported.count, path);
    return ok;
}

void TWContainerExportStart(void) {
    // Crane 可能比 Twin 晚加载，也可能在运行中才建容器：
    // 轮询导出（2 秒后开始，每 4 秒一次，最多 15 次），成功即停。
    __block NSInteger attempts = 0;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                              (uint64_t)(4.0 * NSEC_PER_SEC), (uint64_t)(1.0 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        attempts++;
        if (TWContainerExportNow() || attempts >= 15) {
            dispatch_source_cancel(timer);
        }
    });
    dispatch_resume(timer);
}

// TWContainerExport.m
#import "TWContainerExport.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

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

static id TWE_Call(NSString *selectorName, NSArray *args) {
    Class cls = TWE_CraneManager();
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(selectorName);
    if (![cls respondsToSelector:sel]) return nil;
    @try {
        if (args.count == 0) return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
        if (args.count == 1) return ((id (*)(id, SEL, id))objc_msgSend)(cls, sel, args[0]);
        return ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)(cls, sel, args[0], args[1], NO);
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

void TWContainerExportNow(void) {
    Class cls = TWE_CraneManager();
    if (!cls) return;   // Crane 还没加载：保留上次导出的缓存，不清空。

    id apps = TWE_Call(@"identfiersOfApplicationsThatHaveNonDefaultContainers", @[]);
    if (![apps isKindOfClass:NSArray.class]) return;

    NSMutableArray *exported = [NSMutableArray array];
    for (id item in (NSArray *)apps) {
        if (![item isKindOfClass:NSString.class] || ![item length]) continue;
        NSString *bundleID = item;
        id ids = TWE_Call(@"containerIdentifiersOfApplicationWithIdentifier:", @[bundleID]);
        NSMutableArray *containers = [NSMutableArray arrayWithObject:@{ @"id": @"", @"name": @"默认" }];
        if ([ids isKindOfClass:NSArray.class]) {
            for (id cid in (NSArray *)ids) {
                if (![cid isKindOfClass:NSString.class] || ![cid length]) continue;
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
    [payload writeToFile:path atomically:YES];
    chmod(path.fileSystemRepresentation, 0644);
}

void TWContainerExportStart(void) {
    // Crane 可能比 Twin 晚加载：先等几秒，再在应用启动后刷新。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TWContainerExportNow();
    });
    static id observer;
    if (!observer) {
        observer = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                                     object:nil
                                                                      queue:[NSOperationQueue mainQueue]
                                                                 usingBlock:^(__unused NSNotification *note) {
            TWContainerExportNow();
        }];
    }
}

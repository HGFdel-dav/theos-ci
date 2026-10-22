// CXMenuInjector.m
//
// ParallelX 的菜单条目模型（从真机偏好 com.moxuan.parallelx.plist 读出）：
//   applications      [String]        菜单条目 id：bundleID 或 px.action.* / px.custom.* / px.url.*
//   customActions     [[String:Any]]  px.custom.* 的记录（app / title / kind ...）
//   applicationNames  [String:String] 条目 id -> 菜单显示名
//   shortcutSymbols   [String:String] 条目 id -> SF Symbol
//   shortcutImages    [String:Any]    条目 id -> 自定义图标数据（PX 自己的图片槽）
//
// CloneX 按同一模型注入：每个「应用+容器」= 一条 px.custom.<uuid> 条目，
// 记录里带自定义标题；点击由 CXHook 截住（performConfiguredAction:），
// 先切 Crane 容器，再让 PX 用真实 bundleID 开分屏窗口。
#import "CXMenuInjector.h"
#import "CXPrefs.h"
#import "CXCraneBridge.h"
#import "CXLog.h"
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <string.h>

NSString *const CXMenuIDPrefix = @"px.custom.";

static NSString *const CXPXDomain = @"com.moxuan.parallelx";

#pragma mark - id 生成（稳定、无碰撞）

static NSString *CXVirtualID(NSString *bundleID, NSString *containerID) {
    // FNV-1a 64 → 拼成 UUID 形状，保证同一 (bundle, container) 每次得到同一 id
    uint64_t hash = 1469598103934665603ULL;
    NSString *seed = [NSString stringWithFormat:@"clonex|%@|%@", bundleID, containerID];
    const char *bytes = seed.UTF8String;
    for (size_t i = 0; i < strlen(bytes); i++) {
        hash ^= (uint8_t)bytes[i];
        hash *= 1099511628211ULL;
    }
    uint64_t second = hash ^ 0x9E3779B97F4A7C15ULL;
    return [NSString stringWithFormat:@"%@%08X-%04X-%04X-%04X-%012llX",
            CXMenuIDPrefix,
            (unsigned)(hash >> 32), (unsigned)((hash >> 16) & 0xFFFF),
            (unsigned)(hash & 0xFFFF), (unsigned)((second >> 48) & 0xFFFF),
            (unsigned long long)(second & 0xFFFFFFFFFFFFULL)];
}

static NSMutableDictionary<NSString *, NSDictionary *> *CXIDMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

NSDictionary<NSString *, NSString *> *CXVirtualItemForID(NSString *itemID) {
    if (![itemID isKindOfClass:NSString.class] || ![itemID hasPrefix:CXMenuIDPrefix]) return nil;
    NSDictionary *hit = CXIDMap()[itemID];
    if (hit) return hit;
    // 进程重启后 map 为空：按配置重算一遍
    for (NSDictionary *item in CXPrefs.shared.menuItems) {
        NSString *mid = CXVirtualID(item[@"bundleID"], item[@"containerID"]);
        CXIDMap()[mid] = item;
        if ([mid isEqualToString:itemID]) return item;
    }
    return nil;
}

#pragma mark - PX 偏好读写

static id CXPXRead(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)CXPXDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)CXPXDomain);
    return value ? (__bridge_transfer id)value : nil;
}

static void CXPXWrite(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)CXPXDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)CXPXDomain);
}

#pragma mark - 图标（应用图标 + 「分」角标，PNG）

static UIImage *CXBadgedIcon(NSString *bundleID) {
    CGFloat scale = UIScreen.mainScreen.scale;
    UIImage *base = nil;
    SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([UIImage respondsToSelector:sel])
        base = ((id (*)(id, SEL, id, long, double))objc_msgSend)(UIImage.class, sel, bundleID, 0, (double)scale);
    if (![base isKindOfClass:UIImage.class] || base.size.width <= 0) return nil;

    CGSize size = CGSizeMake(120, 120);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [base drawInRect:CGRectMake(0, 0, size.width, size.height)];
        CGFloat dia = 44;
        CGRect badge = CGRectMake(size.width - dia - 2, size.height - dia - 2, dia, dia);
        UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:badge];
        [[UIColor colorWithWhite:0 alpha:0.78] setFill];
        [circle fill];
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:24 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: UIColor.whiteColor,
        };
        NSString *mark = @"分";
        CGSize textSize = [mark sizeWithAttributes:attrs];
        [mark drawAtPoint:CGPointMake(badge.origin.x + (dia - textSize.width) / 2,
                                      badge.origin.y + (dia - textSize.height) / 2)
           withAttributes:attrs];
    }];
}

#pragma mark - 注入

@implementation CXMenuInjector

+ (NSString *)menuIDForBundleID:(NSString *)bundleID containerID:(NSString *)containerID {
    return CXVirtualID(bundleID, containerID);
}

+ (void)sync {
    NSArray<NSDictionary *> *items = CXPrefs.shared.menuItems;

    // 1) 现有 PX 数据
    NSMutableArray<NSString *> *applications = [NSMutableArray array];
    id appsRaw = CXPXRead(@"applications");
    if ([appsRaw isKindOfClass:NSArray.class])
        for (id entry in appsRaw)
            if ([entry isKindOfClass:NSString.class] && [entry length]) [applications addObject:entry];

    NSMutableArray<NSDictionary *> *customActions = [NSMutableArray array];
    id actionsRaw = CXPXRead(@"customActions");
    if ([actionsRaw isKindOfClass:NSArray.class])
        for (id entry in actionsRaw)
            if ([entry isKindOfClass:NSDictionary.class]) [customActions addObject:entry];

    NSMutableDictionary *names = [NSMutableDictionary dictionary];
    id namesRaw = CXPXRead(@"applicationNames");
    if ([namesRaw isKindOfClass:NSDictionary.class]) [names addEntriesFromDictionary:namesRaw];

    NSMutableDictionary *symbols = [NSMutableDictionary dictionary];
    id symbolsRaw = CXPXRead(@"shortcutSymbols");
    if ([symbolsRaw isKindOfClass:NSDictionary.class]) [symbols addEntriesFromDictionary:symbolsRaw];

    NSMutableDictionary *images = [NSMutableDictionary dictionary];
    id imagesRaw = CXPXRead(@"shortcutImages");
    if ([imagesRaw isKindOfClass:NSDictionary.class]) [images addEntriesFromDictionary:imagesRaw];

    // 2) 清掉上次注入的条目（按 type 标记识别，配置改过也能清干净）
    NSMutableSet<NSString *> *previousIDs = [NSMutableSet set];
    for (NSDictionary *record in customActions)
        if ([record[@"type"] isEqual:@"clonex.open"] && [record[@"id"] isKindOfClass:NSString.class])
            [previousIDs addObject:record[@"id"]];
    for (NSString *entry in previousIDs) {
        [applications removeObject:entry];
        [names removeObjectForKey:entry];
        [symbols removeObjectForKey:entry];
        [images removeObjectForKey:entry];
    }
    [customActions filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *record, id bindings) {
        return ![record[@"type"] isEqual:@"clonex.open"];
    }]];

    // 3) 写入当前配置
    NSMutableDictionary<NSString *, NSDictionary *> *idMap = CXIDMap();
    [idMap removeAllObjects];
    for (NSDictionary *item in items) {
        NSString *bundle = item[@"bundleID"];
        NSString *container = item[@"containerID"];
        if (!bundle.length || !container.length) continue;
        if (![CXCraneBridge isApplicationSupportedByCrane:bundle]) continue;

        NSString *itemID = CXVirtualID(bundle, container);
        idMap[itemID] = item;

        if (![applications containsObject:itemID]) [applications addObject:itemID];
        NSString *appName = bundle;
        Class proxyCls = NSClassFromString(@"LSApplicationProxy");
        if (proxyCls) {
            id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyCls,
                NSSelectorFromString(@"applicationProxyForIdentifier:"), bundle);
            if (proxy) {
                id name = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"localizedName"));
                if ([name isKindOfClass:NSString.class] && [name length]) appName = name;
            }
        }
        NSString *containerName = [CXCraneBridge displayNameForContainer:container bundleID:bundle];
        if (!containerName.length) containerName = container;
        [names setObject:[NSString stringWithFormat:@"%@ · %@", appName, containerName] forKey:itemID];

        BOOL exists = NO;
        for (NSDictionary *record in customActions)
            if ([record[@"id"] isEqual:itemID]) { exists = YES; break; }
        if (!exists) {
            [customActions addObject:@{
                @"id": itemID,
                @"title": names[itemID],
                @"app": bundle,
                @"appTitle": appName,
                @"kind": @"quick",
                @"type": @"clonex.open",
            }];
        }
        if (!symbols[itemID]) symbols[itemID] = @"square.on.square";
        UIImage *icon = CXBadgedIcon(bundle);
        if (icon) {
            NSData *png = UIImagePNGRepresentation(icon);
            if (png) images[itemID] = png;
        }
    }

    // 4) 写回
    CXPXWrite(@"applications", applications);
    CXPXWrite(@"customActions", customActions);
    CXPXWrite(@"applicationNames", names);
    CXPXWrite(@"shortcutSymbols", symbols);
    CXPXWrite(@"shortcutImages", images);
    CXLog(@"[menu] synced %lu clone entries (applications=%lu)",
          (unsigned long)items.count, (unsigned long)applications.count);
}

@end
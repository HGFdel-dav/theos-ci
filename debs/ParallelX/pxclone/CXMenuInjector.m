// CXMenuInjector.m
//
// 自动模式：Crane 里应用有几个容器，菜单里就注入几个条目（默认 + 分身），
// 不需要用户勾选。设置页只负责展示和"整个应用不显示"的开关。
//
// PX 菜单模型（真机 com.moxuan.parallelx.plist）：
//   applications / customActions / applicationNames / shortcutSymbols / shortcutImages
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

#pragma mark - id

static NSString *CXVirtualID(NSString *bundleID, NSString *containerID) {
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

// 由 id 反查 bundle/container：map 里没有时按当前 Crane 容器列表重算
NSDictionary<NSString *, NSString *> *CXVirtualItemForID(NSString *itemID) {
    if (![itemID isKindOfClass:NSString.class] || ![itemID hasPrefix:CXMenuIDPrefix]) return nil;
    NSDictionary *hit = CXIDMap()[itemID];
    if (hit) return hit;
    for (NSString *bundle in [CXCraneBridge applicationsWithNonDefaultContainers]) {
        for (NSDictionary *entry in [CXCraneBridge containersForBundleID:bundle]) {
            NSString *mid = CXVirtualID(bundle, entry[@"containerID"]);
            NSDictionary *item = @{@"bundleID": bundle, @"containerID": entry[@"containerID"]};
            CXIDMap()[mid] = item;
            if ([mid isEqualToString:itemID]) return item;
        }
    }
    return nil;
}

#pragma mark - PX 偏好

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

#pragma mark - 图标（应用图标 + 默/分角标）

static UIImage *CXBadgedIcon(NSString *bundleID, BOOL isDefault) {
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
        [[UIColor colorWithWhite:0 alpha:0.78] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:badge] fill];
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:24 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: UIColor.whiteColor,
        };
        NSString *mark = isDefault ? @"默" : @"分";
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
    // 1) 读出 PX 现有数据
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

    // 2) 只清理"已经不该存在"的条目；已有条目保留原位置（用户在 PX 里拖过的顺序不能被重置）
    // 有效项直接来自 Crane，与下方注入使用相同的容器数量和账号开关条件。
    NSArray<NSString *> *craneApps = [CXCraneBridge applicationsWithNonDefaultContainers];
    NSMutableSet<NSString *> *desiredIDs = [NSMutableSet set];
    for (NSString *bundle in craneApps) {
        if (![bundle isKindOfClass:NSString.class] || !bundle.length) continue;
        NSArray<NSDictionary *> *containers = [CXCraneBridge containersForBundleID:bundle];
        if (containers.count < 2) continue;
        for (NSDictionary *entry in containers) {
            NSString *containerID = entry[@"containerID"];
            if (!containerID.length) continue;
            if (![CXPrefs.shared isItemShownInMenu:bundle containerID:containerID]) continue;
            [desiredIDs addObject:CXVirtualID(bundle, containerID)];
        }
    }
    NSMutableSet<NSString *> *previousIDs = [NSMutableSet set];
    for (NSDictionary *record in customActions)
        if ([record[@"type"] isEqual:@"clonex.open"] && [record[@"id"] isKindOfClass:NSString.class])
            [previousIDs addObject:record[@"id"]];
    for (NSString *entry in previousIDs) {
        if ([desiredIDs containsObject:entry]) continue;   // 仍然有效：位置不动
        [applications removeObject:entry];
        [names removeObjectForKey:entry];
        [symbols removeObjectForKey:entry];
        [images removeObjectForKey:entry];
    }
    // 全部分身记录都从 customActions 移除：旧版本残留的也要清掉，
    // 否则 PX 仍按“快捷动作”走全屏。
    NSMutableArray<NSDictionary *> *keptActions = [NSMutableArray array];
    for (NSDictionary *record in customActions)
        if (![record[@"type"] isEqual:@"clonex.open"]) [keptActions addObject:record];
    [customActions setArray:keptActions];

    // 3) 全自动：Crane 里有几个容器就注入几条
    NSMutableDictionary<NSString *, NSDictionary *> *idMap = CXIDMap();
    [idMap removeAllObjects];
    NSUInteger injected = 0;
    for (NSString *bundle in craneApps) {
        if (![bundle isKindOfClass:NSString.class] || !bundle.length) continue;

        NSArray<NSDictionary *> *containers = [CXCraneBridge containersForBundleID:bundle];
        if (containers.count < 2) continue;   // 只有默认容器的不算分身

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

        for (NSDictionary *entry in containers) {
            NSString *containerID = entry[@"containerID"];
            if (!containerID.length) continue;
            if (![CXPrefs.shared isItemShownInMenu:bundle containerID:containerID]) continue;
            BOOL isDefault = [entry[@"isDefault"] boolValue];
            NSString *itemID = CXVirtualID(bundle, containerID);
            idMap[itemID] = @{@"bundleID": bundle, @"containerID": containerID};

            if (![applications containsObject:itemID]) [applications addObject:itemID];
            NSString *containerName = isDefault ? @"默认" : (entry[@"name"] ?: containerID);
            names[itemID] = [NSString stringWithFormat:@"%@ · %@", appName, containerName];
            BOOL exists = NO;
            for (NSDictionary *record in customActions)
                if ([record[@"id"] isEqual:itemID]) { exists = YES; break; }
            // 不再塞进 customActions：快捷动作会被 PX 按全屏打开。
            // 只留在 applications 里，让 PX 当普通应用走 prepareWindow(fullscreen=0)。
            (void)exists;
            if (!symbols[itemID]) symbols[itemID] = @"square.on.square";
            UIImage *icon = CXBadgedIcon(bundle, isDefault);
            if (icon) {
                NSData *png = UIImagePNGRepresentation(icon);
                if (png) images[itemID] = png;
            }
            injected++;
        }
    }

    // 4) 写回
    CXPXWrite(@"applications", applications);
    CXPXWrite(@"customActions", customActions);
    CXPXWrite(@"applicationNames", names);
    CXPXWrite(@"shortcutSymbols", symbols);
    CXPXWrite(@"shortcutImages", images);
    CXLog(@"[menu] synced %lu entries for %lu apps", (unsigned long)injected, (unsigned long)craneApps.count);
}

@end
// TWRemember.m — remember the *shape* of every app/container panel (0.4.0).
//
// 0.3.x remembered a single wide window frame per bundleID. 0.4.0 stores a
// shape snapshot per "bundleID|containerID" (spec §5):
//   p/l      wide (大窗) frame, portrait / landscape
//   docked   panel width < screen width * 0.55  (缩小/贴边)
//   side     0 = panel centre left of screen centre, 1 = right
//   updated  NSDate of the last capture
//   dp/dl    the narrow frame captured while docked + dw/dh/dy screen ratios
// The two memories are deliberately kept apart: while docked we only touch
// dp/dl/dw/dh/dy, never p/l — otherwise the narrow docked frame would pollute
// the wide window memory. Same split as ScreenCore's
// -sc_shouldRememberFrameForSession:.
//
// Optional ParallelX integration: hooks are installed only when PXPanelEntry is
// present, and they were verified from the device-installed ParallelX.dylib
// ObjC metadata:
//   -[PXPanelEntry applyResizePreview]      v16@0:8   — resize commit
//   -[PXPanelEntry moveHost:]               v24@0:8@16 — move gesture
//   -[PXPanelEntry closeTapped]             v16@0:8   — window close
//   -[PXPanelEntry init]                    @16@0:8   — fresh entry
//   ivars (object): hostedBundleID, panelWindow, resizePreview, draggingHandle,
//                   dockedHosts, fullscreenToWindowInProgress
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <math.h>
#import <string.h>
#import "TWRemember.h"
#import "TWPrefs.h"
#import "TWCraneBridge.h"

// TWPath.h owns the preference keys; this guard is the fallback required by the
// spec (TWPath.h itself is not ours to edit) so the module builds stand-alone.
#ifndef TWKeyRememberStates
#define TWKeyRememberStates @"TWRememberStates"  // dict { "bundleID|containerID" : state }
#endif

#pragma mark - constants

// Spec §5: docked (缩小/贴边) ⇔ panel width < screen width * 0.55.
static const CGFloat TWDockedWidthRatio = 0.55;
// Sanity window for the docked width ratio we keep for restore-time scaling.
static const CGFloat TWDockedRatioMin = 0.10;
static const CGFloat TWDockedRatioMax = 0.55;
// Fallback width ratio when an entry is docked but carries no usable ratio.
static const CGFloat TWDockedRatioFallback = 0.42;
// Internal marker inside the TWKeyRememberStates container: the legacy
// TWKeyRememberFrames migration runs once and never resurrects deleted entries.
static NSString *const TWRememberMigratedMarker = @"__legacyMigrated";
static NSString *const TWRememberKeySeparator = @"|";

#pragma mark - ivar helpers (runtime, Swift ivars are visible to the ObjC runtime)

static id TWObjIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable([obj class], name);
    if (!ivar) {
        unsigned int count = 0;
        Ivar *list = class_copyIvarList([obj class], &count);
        for (unsigned int i = 0; i < count && !ivar; i++) {
            const char *n = ivar_getName(list[i]);
            if (n && strcmp(n, name) == 0) ivar = list[i];
        }
        free(list);
    }
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return nil; // object ivars only (object_getIvar)
    id value = object_getIvar(obj, ivar);
    return [(NSObject *)value isKindOfClass:NSObject.class] ? value : nil;
}

static NSString *TWStringIvar(id obj, const char *const *names, size_t count) {
    for (size_t i = 0; i < count; i++) {
        id value = TWObjIvar(obj, names[i]);
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return nil;
}

static NSString *TWBundleIDOfEntry(NSObject *entry) {
    static const char *const names[] = { "hostedBundleID", "hostBundleID", "bundleID" };
    return TWStringIvar(entry, names, sizeof(names) / sizeof(names[0]));
}

// ParallelX stores the Crane container of an entry in an ivar whose exact name
// is not part of the dump; every plausible name is probed and a missing ivar
// falls back to the container Twin just opened (TWKeyLastLaunch) and then to
// Crane's currently active container.
static NSString *TWContainerFallbackForBundle(NSString *bundleID) {
    if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) return @"";
    @try {
        id last = [[TWPrefs shared] objectForKey:TWKeyLastLaunch];
        if ([last isKindOfClass:NSDictionary.class]) {
            NSString *lastBundle = last[@"bundleID"];
            NSString *lastContainer = last[@"containerID"];
            id at = last[@"at"];
            BOOL fresh = ![at isKindOfClass:NSDate.class] || -[(NSDate *)at timeIntervalSinceNow] < 20.0;
            if (fresh && [lastBundle isKindOfClass:NSString.class] && [lastBundle isEqual:bundleID] &&
                [lastContainer isKindOfClass:NSString.class] && lastContainer.length) {
                return lastContainer;
            }
        }
    } @catch (__unused NSException *exception) {}
    @try {
        NSString *active = [TWCraneBridge activeContainerForBundleID:bundleID];
        if ([active isKindOfClass:NSString.class]) return active ?: @"";
    } @catch (__unused NSException *exception) {}
    return @"";
}

static NSString *TWContainerIDOfEntry(NSObject *entry) {
    static const char *const names[] = { "hostedContainerID", "hostedContainerIdentifier",
                                         "containerID", "containerIdentifier", "container" };
    NSString *container = TWStringIvar(entry, names, sizeof(names) / sizeof(names[0]));
    if (container.length) return container;
    return TWContainerFallbackForBundle(TWBundleIDOfEntry(entry));
}

#pragma mark - switches (live value on every capture)

static BOOL TWTwinEnabled(void) {
    return [TWPrefs.shared boolForKey:TWKeyEnabled defaultValue:NO];
}

static BOOL TWRememberEnabled(void) {
    // 总开关 TWKeyRememberSize: TWPrefs reads through to disk on every call, so
    // flipping the switch in Settings takes effect without a respring.
    // Default is NO as of 0.4.0 (spec §2).
    return TWTwinEnabled() && [TWPrefs.shared boolForKey:TWKeyRememberSize defaultValue:NO];
}

static BOOL TWCanRemember(NSObject *entry) {
    if (![entry isKindOfClass:NSObject.class]) return NO;
    // Do not capture while a resize is in progress or while a window is on its
    // way to fullscreen. dockedHosts is deliberately NO veto any more: an entry
    // that is docked (缩小/贴边) is exactly the shape we now have to record.
    id resizePreview = TWObjIvar(entry, "resizePreview");
    if (resizePreview) return NO;
    id fullscreen = TWObjIvar(entry, "fullscreenToWindowInProgress");
    if ([fullscreen respondsToSelector:@selector(boolValue)] && [fullscreen boolValue]) return NO;
    return YES;
}

static UIWindow *TWPanelWindowOf(NSObject *entry) {
    id w = TWObjIvar(entry, "panelWindow");
    return [w isKindOfClass:UIWindow.class] ? w : nil;
}

static CGRect TWScreenBoundsOfWindow(UIWindow *window) {
    CGRect bounds = CGRectNull;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = window.windowScene;
        if ([scene isKindOfClass:UIWindowScene.class]) bounds = scene.screen.bounds;
    }
    if (CGRectIsNull(bounds) || CGRectIsEmpty(bounds)) bounds = UIScreen.mainScreen.bounds;
    return (CGRectIsNull(bounds) || CGRectIsEmpty(bounds)) ? CGRectNull : bounds;
}

#pragma mark - plist-safe value helpers (never keep a temporary pointer alive)

static BOOL TWIsUsableFrame(CGRect frame) {
    if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) return NO;
    if (!isfinite(frame.origin.x) || !isfinite(frame.origin.y) ||
        !isfinite(frame.size.width) || !isfinite(frame.size.height)) return NO;
    if (frame.size.width <= 0 || frame.size.height <= 0) return NO;
    if (frame.size.width > 5000 || frame.size.height > 5000) return NO;
    if (fabs(frame.origin.x) > 10000 || fabs(frame.origin.y) > 10000) return NO;
    return YES;
}

static NSDictionary *TWFrameDictFromRect(CGRect frame) {
    if (!TWIsUsableFrame(frame)) return nil;
    return @{ @"x": @(frame.origin.x), @"y": @(frame.origin.y),
              @"w": @(frame.size.width), @"h": @(frame.size.height) };
}

static CGRect TWRectFromFrameValue(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return CGRectNull;
    NSNumber *x = value[@"x"], *y = value[@"y"], *w = value[@"w"], *h = value[@"h"];
    if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class] ||
        ![w isKindOfClass:NSNumber.class] || ![h isKindOfClass:NSNumber.class]) return CGRectNull;
    CGRect frame = CGRectMake(x.doubleValue, y.doubleValue, w.doubleValue, h.doubleValue);
    return TWIsUsableFrame(frame) ? frame : CGRectNull;
}

static double TWDoubleFromValue(id value) {
    if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) {
        double d = [value doubleValue];
        return isfinite(d) ? d : NAN;
    }
    return NAN;
}

static BOOL TWBOOLFromValue(id value, BOOL fallback) {
    if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) return [value boolValue];
    return fallback;
}

static NSDate *TWDateFromValue(id value) {
    if ([value isKindOfClass:NSDate.class]) return value;
    if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class])
        return [NSDate dateWithTimeIntervalSince1970:[value doubleValue]];
    return nil;
}

#pragma mark - keys & canonical state

static NSString *TWRememberNormalizedContainer(NSString *containerID) {
    NSString *trimmed = [containerID isKindOfClass:NSString.class]
        ? [containerID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
    return trimmed.length ? trimmed : @"";
}

// "bundleID|containerID" — the container part is empty for the default container.
static NSString *TWRememberKeyForEntry(NSString *bundleID, NSString *containerID) {
    if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) return nil;
    return [NSString stringWithFormat:@"%@%@%@", bundleID, TWRememberKeySeparator,
            TWRememberNormalizedContainer(containerID)];
}

static void TWSplitRememberKey(NSString *key, NSString **bundleID, NSString **containerID) {
    NSRange separator = [key rangeOfString:TWRememberKeySeparator];
    if (separator.location == NSNotFound) {
        if (bundleID) *bundleID = key;
        if (containerID) *containerID = @"";
        return;
    }
    if (bundleID) *bundleID = [key substringToIndex:separator.location];
    if (containerID) *containerID = [key substringFromIndex:NSMaxRange(separator)];
}

// Canonical snapshot: unknown fields dropped, unusable frames dropped, strings
// copied, timestamps normalised to NSDate. Returns nil when the entry cannot be
// identified at all.
static NSDictionary *TWSanitizedState(NSString *bundleID, NSString *containerID, NSDictionary *raw) {
    if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) return nil;
    if (![raw isKindOfClass:NSDictionary.class] || ![(NSDictionary *)raw count]) return nil;
    NSString *container = TWRememberNormalizedContainer(containerID);
    NSString *key = TWRememberKeyForEntry(bundleID, container);
    if (!key.length) return nil;
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"bundleID"] = [bundleID copy];
    state[@"containerID"] = [container copy];
    state[@"key"] = key;
    for (NSString *name in @[ @"p", @"l", @"dp", @"dl" ]) {
        NSDictionary *frame = TWFrameDictFromRect(TWRectFromFrameValue(raw[name]));
        if (frame) state[name] = frame;
    }
    state[@"docked"] = @(TWBOOLFromValue(raw[@"docked"], NO));
    state[@"side"] = @(TWBOOLFromValue(raw[@"side"], NO) ? 1 : 0);
    double dw = TWDoubleFromValue(raw[@"dw"]);
    if (!isnan(dw) && dw > 0.0 && dw <= 1.0) state[@"dw"] = @(dw);
    double dh = TWDoubleFromValue(raw[@"dh"]);
    if (!isnan(dh) && dh > 0.0 && dh <= 1.0) state[@"dh"] = @(dh);
    double dy = TWDoubleFromValue(raw[@"dy"]);
    if (!isnan(dy) && dy >= 0.0 && dy <= 1.0) state[@"dy"] = @(dy);
    NSDate *updated = TWDateFromValue(raw[@"updated"]) ?: [NSDate date];
    state[@"updated"] = updated;
    state[@"updatedAt"] = @(updated.timeIntervalSince1970);
    return state;
}

static NSDictionary *TWStoredStates(void) {
    id all = [[TWPrefs shared] objectForKey:TWKeyRememberStates];
    return [all isKindOfClass:NSDictionary.class] ? all : nil;
}

#pragma mark - public state API

NSDictionary *TWRememberStateForEntry(NSString *bundleID, NSString *containerID) {
    if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) return nil;
    @try {
        NSDictionary *all = TWStoredStates();
        if (!all) return nil;
        NSString *key = TWRememberKeyForEntry(bundleID, containerID);
        id raw = key.length ? all[key] : nil;
        if (![raw isKindOfClass:NSDictionary.class]) return nil;
        return TWSanitizedState(bundleID, containerID, raw);
    } @catch (__unused NSException *exception) { return nil; }
}

void TWRememberStoreState(NSString *bundleID, NSString *containerID, NSDictionary *state) {
    if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) return;
    NSString *key = TWRememberKeyForEntry(bundleID, containerID);
    if (!key.length) return;
    @try {
        id all = [[TWPrefs shared] objectForKey:TWKeyRememberStates];
        NSMutableDictionary *states = [all isKindOfClass:NSDictionary.class]
            ? [all mutableCopy] : [NSMutableDictionary dictionary];
        if (![state isKindOfClass:NSDictionary.class] || ![(NSDictionary *)state count]) {
            // nil / empty snapshot removes this entry (the panel's per-row delete).
            [states removeObjectForKey:key];
        } else {
            // Merge, so a partial update (e.g. only docked/side) can never wipe a
            // previously remembered wide-window frame. NSNull clears one field.
            NSMutableDictionary *merged = [states[key] isKindOfClass:NSDictionary.class]
                ? [(NSDictionary *)states[key] mutableCopy] : [NSMutableDictionary dictionary];
            for (id field in state) {
                if (![field isKindOfClass:NSString.class]) continue;
                id value = state[field];
                if ([value isKindOfClass:NSNull.class]) [merged removeObjectForKey:field];
                else merged[field] = value;
            }
            NSDictionary *clean = TWSanitizedState(bundleID, containerID, merged);
            if (!clean) return;
            states[key] = clean;
        }
        [[TWPrefs shared] setObject:states forKey:TWKeyRememberStates];
        [[TWPrefs shared] synchronize];
    } @catch (__unused NSException *exception) { }
}

void TWRememberResetAll(void) {
    @try {
        // Keep the internal migration marker so deleted legacy frames are never
        // resurrected, but drop every entry — and the legacy store itself.
        [[TWPrefs shared] setObject:@{ TWRememberMigratedMarker: @(YES) } forKey:TWKeyRememberStates];
        [[TWPrefs shared] clearRememberedFrames];
        [[TWPrefs shared] synchronize];
    } @catch (__unused NSException *exception) { }
}

#pragma mark - display names (runtime-resolved, never a compile-time private dep)

static const char *TWRuntimeType(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type ?: "";
}

// ABI-checked object-returning call: skips anything whose signature we do not
// actually match, so a private API change degrades to "no name" and never crashes.
static id TWCallObject(id target, NSString *name, id argument, BOOL hasArgument) {
    SEL selector = NSSelectorFromString(name);
    @try {
        if (!target || ![target respondsToSelector:selector]) return nil;
        NSMethodSignature *signature = [target methodSignatureForSelector:selector];
        if (!signature || signature.numberOfArguments != (hasArgument ? 3 : 2)) return nil;
        if (TWRuntimeType(signature.methodReturnType)[0] != '@') return nil;
        if (hasArgument && TWRuntimeType([signature getArgumentTypeAtIndex:2])[0] != '@') return nil;
        if (hasArgument) return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, argument);
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) { return nil; }
}

static NSString *TWFirstStringFromCalls(id target, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        id value = TWCallObject(target, name, nil, NO);
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return nil;
}

static NSString *TWAppDisplayName(NSString *bundleID) {
    if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) return nil;
    @try {
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        id proxy = TWCallObject(proxyClass, @"applicationProxyForIdentifier:", bundleID, YES);
        NSString *name = TWFirstStringFromCalls(proxy, @[ @"localizedName", @"itemName", @"shortName" ]);
        if (name.length) return name;
        Class controllerClass = NSClassFromString(@"SBApplicationController");
        id controller = TWCallObject(controllerClass, @"sharedInstance", nil, NO);
        id application = TWCallObject(controller, @"applicationWithBundleIdentifier:", bundleID, YES);
        name = TWFirstStringFromCalls(application, @[ @"displayName", @"shortDisplayName" ]);
        if (name.length) return name;
        NSBundle *bundle = [NSBundle bundleWithIdentifier:bundleID];
        id display = bundle.localizedInfoDictionary[@"CFBundleDisplayName"] ?: bundle.infoDictionary[@"CFBundleDisplayName"];
        if ([display isKindOfClass:NSString.class] && [display length]) return display;
    } @catch (__unused NSException *exception) { }
    return nil;
}

// Crane exposes container names; the 3-argument form is only called when the
// signature matches (object, object, one-byte scalar → object).
static NSString *TWContainerDisplayName(NSString *containerID, NSString *bundleID) {
    if (![containerID isKindOfClass:NSString.class] || !containerID.length) return nil;
    if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) return nil;
    Class manager = NSClassFromString(@"CraneManager");
    if (!manager) return nil;
    SEL selector = NSSelectorFromString(@"displayNameForContainerWithIdentifier:ofApplicationWithIdentifier:shouldUseShortVersion:");
    @try {
        if (![manager respondsToSelector:selector]) return nil;
        NSMethodSignature *signature = [manager methodSignatureForSelector:selector];
        if (!signature || signature.numberOfArguments != 5) return nil;
        if (TWRuntimeType(signature.methodReturnType)[0] != '@') return nil;
        if (TWRuntimeType([signature getArgumentTypeAtIndex:2])[0] != '@') return nil;
        if (TWRuntimeType([signature getArgumentTypeAtIndex:3])[0] != '@') return nil;
        const char *flag = TWRuntimeType([signature getArgumentTypeAtIndex:4]);
        id result = nil;
        if (flag[0] == 'c' || flag[0] == 'B' || flag[0] == 'C') {
            result = ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)(manager, selector, containerID, bundleID, NO);
        } else {
            return nil;
        }
        return [result isKindOfClass:NSString.class] && [(NSString *)result length] ? result : nil;
    } @catch (__unused NSException *exception) { return nil; }
}

#pragma mark - summary (for the settings list)

static NSString *TWSizeTextForState(NSDictionary *state) {
    CGRect frame = TWRectFromFrameValue(state[@"p"]);
    if (CGRectIsNull(frame)) frame = TWRectFromFrameValue(state[@"l"]);
    if (CGRectIsNull(frame)) frame = TWRectFromFrameValue(state[@"dp"]);
    if (CGRectIsNull(frame)) frame = TWRectFromFrameValue(state[@"dl"]);
    if (CGRectIsNull(frame)) return @"";
    return [NSString stringWithFormat:@"%.0f×%.0f", frame.size.width, frame.size.height];
}

static NSString *TWStateTextForState(NSDictionary *state) {
    if (!TWBOOLFromValue(state[@"docked"], NO)) return @"大窗";
    return TWBOOLFromValue(state[@"side"], NO) ? @"缩小·右" : @"缩小·左";
}

// "微信 · 分 · 428×892 · 缩小·右"
static NSString *TWSummaryForState(NSDictionary *state) {
    NSString *bundleID = [state[@"bundleID"] isKindOfClass:NSString.class] ? state[@"bundleID"] : @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *name = TWAppDisplayName(bundleID);
    [parts addObject:(name.length ? name : (bundleID.length ? bundleID : @"未知应用"))];
    NSString *container = TWRememberNormalizedContainer(state[@"containerID"]);
    if (container.length) [parts addObject:(TWContainerDisplayName(container, bundleID) ?: @"分")];
    NSString *size = TWSizeTextForState(state);
    if (size.length) [parts addObject:size];
    [parts addObject:TWStateTextForState(state)];
    return [parts componentsJoinedByString:@" · "];
}

NSArray<NSDictionary *> *TWRememberAllStates(void) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    @try {
        NSDictionary *all = TWStoredStates();
        if (!all) return items;
        for (id rawKey in all) {
            if (![rawKey isKindOfClass:NSString.class] || ![rawKey length]) continue;
            if ([rawKey hasPrefix:@"__"]) continue; // internal markers, not entries
            NSDictionary *raw = all[rawKey];
            if (![raw isKindOfClass:NSDictionary.class] || ![(NSDictionary *)raw count]) continue;
            NSString *bundleID = nil, *containerID = nil;
            TWSplitRememberKey(rawKey, &bundleID, &containerID);
            id storedBundle = raw[@"bundleID"];
            if ([storedBundle isKindOfClass:NSString.class] && [storedBundle length]) bundleID = storedBundle;
            id storedContainer = raw[@"containerID"];
            if ([storedContainer isKindOfClass:NSString.class]) containerID = storedContainer;
            NSDictionary *state = TWSanitizedState(bundleID, containerID, raw);
            if (!state) continue;
            NSMutableDictionary *item = [state mutableCopy];
            item[@"summary"] = TWSummaryForState(state);
            item[@"sizeText"] = TWSizeTextForState(state);
            item[@"stateText"] = TWStateTextForState(state);
            [items addObject:item];
        }
    } @catch (__unused NSException *exception) { }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSDate *da = a[@"updated"], *db = b[@"updated"];
        NSTimeInterval ta = [da isKindOfClass:NSDate.class] ? da.timeIntervalSince1970 : 0;
        NSTimeInterval tb = [db isKindOfClass:NSDate.class] ? db.timeIntervalSince1970 : 0;
        if (ta != tb) return ta > tb ? NSOrderedAscending : NSOrderedDescending;
        NSString *ka = [a[@"key"] isKindOfClass:NSString.class] ? a[@"key"] : @"";
        NSString *kb = [b[@"key"] isKindOfClass:NSString.class] ? b[@"key"] : @"";
        return [ka compare:kb];
    }];
    return items;
}

#pragma mark - one-shot legacy migration (TWKeyRememberFrames → TWKeyRememberStates)

// 旧 TWKeyRememberFrames ({bundleID:{x,y,w,h}}) 只读一次做迁移；
// 迁移后不删除旧键（保守），只写一个内部标记避免重复迁移／复活已删除条目。
static void TWRememberMigrateLegacyFrames(void) {
    @try {
        id all = [[TWPrefs shared] objectForKey:TWKeyRememberStates];
        NSMutableDictionary *states = [all isKindOfClass:NSDictionary.class]
            ? [all mutableCopy] : [NSMutableDictionary dictionary];
        if (TWBOOLFromValue(states[TWRememberMigratedMarker], NO)) return;
        NSDictionary *legacy = [[TWPrefs shared] objectForKey:TWKeyRememberFrames];
        if ([legacy isKindOfClass:NSDictionary.class]) {
            for (id oldBundle in legacy) {
                if (![oldBundle isKindOfClass:NSString.class] || ![oldBundle length]) continue;
                NSDictionary *frameDict = TWFrameDictFromRect(TWRectFromFrameValue(legacy[oldBundle]));
                if (!frameDict) continue;
                NSString *key = TWRememberKeyForEntry(oldBundle, nil);
                if (!key.length || states[key]) continue;
                // 旧记录不区分横竖屏：两向各放一份，避免方向不匹配时恢复不了。
                states[key] = @{ @"bundleID": [oldBundle copy], @"containerID": @"", @"key": key,
                                 @"p": frameDict, @"l": frameDict,
                                 @"docked": @(NO), @"side": @(0),
                                 @"updated": [NSDate date] };
            }
        }
        states[TWRememberMigratedMarker] = @(YES);
        [[TWPrefs shared] setObject:states forKey:TWKeyRememberStates];
        [[TWPrefs shared] synchronize];
    } @catch (__unused NSException *exception) { }
}

#pragma mark - capture (shape snapshot)

static void TWCaptureEntry(NSObject *entry) {
    if (!TWRememberEnabled()) return;
    if (!TWCanRemember(entry)) return;
    UIWindow *window = TWPanelWindowOf(entry);
    NSString *bundleID = TWBundleIDOfEntry(entry);
    if (!window || !bundleID.length) return;
    CGRect frame = window.frame;
    if (!TWIsUsableFrame(frame)) return;
    CGRect screen = TWScreenBoundsOfWindow(window);
    if (CGRectIsNull(screen)) return;
    // Require the window to intersect the main screen bounds (not stashed offscreen).
    if (!CGRectIntersectsRect(CGRectInset(screen, -2, -2), frame)) return;
    @try {
        BOOL portrait = screen.size.height >= screen.size.width;
        BOOL docked = frame.size.width < screen.size.width * TWDockedWidthRatio;
        NSInteger side = (CGRectGetMidX(frame) < CGRectGetMidX(screen)) ? 0 : 1;
        NSString *containerID = TWContainerIDOfEntry(entry);
        NSMutableDictionary *state = [NSMutableDictionary dictionary];
        NSDictionary *previous = TWRememberStateForEntry(bundleID, containerID);
        if (previous) [state addEntriesFromDictionary:previous];
        state[@"docked"] = @(docked);
        state[@"side"] = @(side);
        state[@"updated"] = [NSDate date];
        if (docked) {
            // 缩小/贴边态：只更新「缩小记忆」(窄框 dp/dl + 屏幕比例)，
            // 绝不能写 p/l —— 否则窄框会污染大窗记忆。对齐 ScreenCore 的
            // -sc_shouldRememberFrameForSession: 把两种记忆分开存的做法。
            NSDictionary *dockedFrame = TWFrameDictFromRect(frame);
            if (!dockedFrame) return;
            state[portrait ? @"dp" : @"dl"] = dockedFrame;
            state[@"dw"] = @(frame.size.width / screen.size.width);
            state[@"dh"] = @(frame.size.height / screen.size.height);
            state[@"dy"] = @(fmax(0.0, frame.origin.y / screen.size.height));
        } else {
            // 宽窗态：只写当向的 p/l；缩小记忆原样保留，下次缩小仍按上次的窄框恢复。
            NSDictionary *wideFrame = TWFrameDictFromRect(frame);
            if (!wideFrame) return;
            state[portrait ? @"p" : @"l"] = wideFrame;
        }
        TWRememberStoreState(bundleID, containerID, state);
    } @catch (__unused NSException *exception) { }
}

#pragma mark - restore

// The docked target is rebuilt from the stored ratios so it always fits the
// current screen width, then pinned back to the recorded left/right edge.
static CGRect TWDockedTargetForState(NSDictionary *state, CGRect screen) {
    double ratio = TWDoubleFromValue(state[@"dw"]);
    if (isnan(ratio) || ratio <= 0) {
        CGRect recorded = TWRectFromFrameValue(state[@"dp"]);
        if (CGRectIsNull(recorded)) recorded = TWRectFromFrameValue(state[@"dl"]);
        if (!CGRectIsNull(recorded) && screen.size.width > 0) ratio = recorded.size.width / screen.size.width;
    }
    if (isnan(ratio) || ratio <= 0) ratio = TWDockedRatioFallback;
    if (ratio < TWDockedRatioMin) ratio = TWDockedRatioMin;
    if (ratio > TWDockedRatioMax) ratio = TWDockedRatioMax;
    CGFloat width = floor(screen.size.width * ratio);
    double heightRatio = TWDoubleFromValue(state[@"dh"]);
    if (isnan(heightRatio) || heightRatio <= 0.2 || heightRatio > 1.0) heightRatio = 1.0;
    CGFloat height = floor(screen.size.height * heightRatio);
    double yRatio = TWDoubleFromValue(state[@"dy"]);
    if (isnan(yRatio) || yRatio < 0 || yRatio > 1.0) yRatio = 0;
    CGFloat y = screen.origin.y + floor(screen.size.height * yRatio);
    BOOL right = TWBOOLFromValue(state[@"side"], NO);
    CGFloat x = right ? CGRectGetMaxX(screen) - width : screen.origin.x;
    return CGRectMake(x, y, width, height);
}

// Wide window memory for the current orientation, falling back to the other one.
static CGRect TWWideTargetForState(NSDictionary *state, CGRect screen) {
    BOOL portrait = screen.size.height >= screen.size.width;
    CGRect frame = TWRectFromFrameValue(state[portrait ? @"p" : @"l"]);
    if (CGRectIsNull(frame)) frame = TWRectFromFrameValue(state[portrait ? @"l" : @"p"]);
    return frame;
}

static void TWApplyRememberedFrame(NSObject *entry) {
    if (!TWRememberEnabled()) return;
    if (!TWCanRemember(entry)) return;
    UIWindow *window = TWPanelWindowOf(entry);
    NSString *bundleID = TWBundleIDOfEntry(entry);
    if (!window || !bundleID.length) return;
    NSDictionary *state = TWRememberStateForEntry(bundleID, TWContainerIDOfEntry(entry));
    if (!state) return;
    CGRect screen = TWScreenBoundsOfWindow(window);
    if (CGRectIsNull(screen)) return;
    // 上次是缩小态 → 这次打开就是缩小的样子；否则恢复记住的大窗 frame。
    CGRect target = TWBOOLFromValue(state[@"docked"], NO)
        ? TWDockedTargetForState(state, screen) : TWWideTargetForState(state, screen);
    if (!TWIsUsableFrame(target)) return;
    // Clamp into screen so a rotated or resized device never loses the window.
    if (target.size.width > screen.size.width) target.size.width = screen.size.width;
    if (target.size.height > screen.size.height) target.size.height = screen.size.height;
    target.origin.x = fmin(fmax(target.origin.x, screen.origin.x - target.size.width + 80),
                           screen.origin.x + screen.size.width - 80);
    target.origin.y = fmin(fmax(target.origin.y, screen.origin.y + 20),
                           screen.origin.y + screen.size.height - 80);
    CGRect current = window.frame;
    if (fabs(target.origin.x - current.origin.x) < 1 && fabs(target.origin.y - current.origin.y) < 1 &&
        fabs(target.size.width - current.size.width) < 1 && fabs(target.size.height - current.size.height) < 1) return;
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        window.frame = target;
    } completion:nil];
}

// A fresh entry may not have its panelWindow yet; retry a few times (main queue).
static void TWApplyRememberedFrameWithRetry(NSObject *entry, NSUInteger attempt) {
    if (!TWRememberEnabled()) return;
    if (!TWPanelWindowOf(entry) && attempt < 3) {
        __weak NSObject *weakEntry = entry;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSObject *strongEntry = weakEntry;
            if (strongEntry) TWApplyRememberedFrameWithRetry(strongEntry, attempt + 1);
        });
        return;
    }
    TWApplyRememberedFrame(entry);
}

#pragma mark - hooks

// moveHost: fires continuously; debounce the save to capture the final position.
// Debounce is a plain main-queue delayed block with a generation token — the
// previous dispatch-source implementation called dispatch_resume on every move,
// which over-resumes the source and can abort the process.
static void (*origMoveHost)(id, SEL, id);
static void replMoveHost(id self, SEL _cmd, id gesture) {
    origMoveHost(self, _cmd, gesture);
    if (!TWRememberEnabled()) return;
    static __weak NSObject *pendingEntry;
    static NSUInteger generation;
    pendingEntry = self;                 // main-queue only (gesture handler)
    NSUInteger token = ++generation;     // main-queue only
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != generation) return; // superseded by a newer move
        NSObject *entry = pendingEntry;
        pendingEntry = nil;
        if (entry) TWCaptureEntry(entry);
    });
}

static void (*origApplyResizePreview)(id, SEL);
static void replApplyResizePreview(id self, SEL _cmd) {
    origApplyResizePreview(self, _cmd);
    TWCaptureEntry(self);
}

static void (*origCloseTapped)(id, SEL);
static void replCloseTapped(id self, SEL _cmd) {
    TWCaptureEntry(self);
    origCloseTapped(self, _cmd);
}

static id (*origInit)(id, SEL);
static id replInit(id self, SEL _cmd) {
    self = origInit(self, _cmd);
    if (self) {
        // Apply the remembered shape shortly after a fresh entry lays out.
        __weak NSObject *weakEntry = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSObject *entry = weakEntry;
            if (entry) TWApplyRememberedFrameWithRetry(entry, 0);
        });
    }
    return self;
}

#pragma mark - installation (ABI-checked, optional ParallelX integration)

typedef void (*TWMSHookFn)(Class, SEL, IMP, IMP *);

static BOOL TWInstallMethod(Class cls, BOOL isClassMethod, SEL sel,
                             IMP replacement, IMP *origSlot, const char *expectedTypes) {
    Class target = isClassMethod ? object_getClass(cls) : cls;
    Method method = class_getInstanceMethod(target, sel);
    if (!method) return NO;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (!sig || strcmp(sig.methodReturnType, expectedTypes) != 0) return NO;
    TWMSHookFn hook = (TWMSHookFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!hook) return NO;
    hook(target, sel, replacement, origSlot);
    return *origSlot != NULL;
}

void TWRememberStart(void) {
    static BOOL started = NO;
    if (started) return;
    // Legacy frames migrate even when ParallelX is absent, so the settings list
    // can already show them. The migration itself is marker-guarded/idempotent.
    TWRememberMigrateLegacyFrames();
    Class cls = objc_getClass("PXPanelEntry");
    if (!cls) return; // ParallelX not installed: window memory is simply inactive
    // Verify the class is the entry we expect (has the ivars we read).
    if (class_getInstanceVariable(cls, "hostedBundleID") == NULL) return;
    BOOL ok = YES;
    ok &= TWInstallMethod(cls, NO, sel_registerName("applyResizePreview"), (IMP)replApplyResizePreview, (IMP *)&origApplyResizePreview, "v");
    ok &= TWInstallMethod(cls, NO, sel_registerName("moveHost:"), (IMP)replMoveHost, (IMP *)&origMoveHost, "v");
    ok &= TWInstallMethod(cls, NO, sel_registerName("closeTapped"), (IMP)replCloseTapped, (IMP *)&origCloseTapped, "v");
    ok &= TWInstallMethod(cls, NO, sel_registerName("init"), (IMP)replInit, (IMP *)&origInit, "@");
    if (ok) started = YES;
}

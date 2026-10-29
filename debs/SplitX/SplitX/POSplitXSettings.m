//
//  POSplitXSettings.m
//  SplitX
//

#import "POSplitXSettings.h"
#import "POSplitXLog.h"
#import "POApplicationHelper.h"

static NSString *const PXDomain = @"com.niubiprass.splitx";
/// 设置页用 suite 写入；这里必须读同一个域，不能用 standardUserDefaults（那是 SpringBoard 自己的域）。
static NSUserDefaults *PXDefaults(void) {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ defaults = [[NSUserDefaults alloc] initWithSuiteName:PXDomain]; });
    return defaults;
}
static void PXSettingsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                              const void *object, CFDictionaryRef userInfo) {
    [[POSplitXSettings shared] reload];
    // POApplicationHelper 把设置缓存住了，不主动清就一直用启动时的旧值。
    [POApplicationHelper reloadSettings];
    PXLog(@"prefs", @"settings-changed 已重载");
}
static NSArray<NSString *> *PXAllowedKeys(void) {
    return @[@"iconSize", @"tileSize", @"itemSpacing", @"panelRadius", @"panelAlpha",
             @"panelColumns", @"fanRadius", @"fanSpan", @"animationSpeed", @"squareIcons", @"hapticFeedback", @"handleAlwaysVisible", @"portraitExternalKeyboard", @"landscapeExternalKeyboard", @"closeOutsideWithKeyboard", @"internalKeyboardZoomPercent", @"externalKeyboardHorizontalPercent", @"keyboardDimOpacity", @"cloneEnabled", @"cloneShowDefault", @"ring1", @"ring2", @"ring3", @"ring4", @"ringGap", @"handleSlideDistance", @"panelEdgeInset", @"topGestureWidth", @"topGestureHeight", @"topGestureOffset", @"bottomGestureWidth", @"bottomGestureHeight", @"bottomGestureOffset", @"showGestureArea", @"windowWidthPercent", @"windowInset", @"windowInsetLandscape", @"windowWidthLandscape", @"windowCornerRadiusLandscape", @"windowMaxScalePercent", @"windowCornerRadius", @"windowShadowStrength", @"windowShadowBlur", @"dockNewSplitPushesCurrent", @"dockWidthPortrait", @"dockWidthLandscape", @"dockAutoStashSeconds", @"dockMaxCount", @"triggerWidth", @"triggerOffsetY", @"dockEnabled", @"dockScale"];
}

@implementation POSplitXSettings {
    NSMutableDictionary<NSString *, id> *_values;
}

+ (instancetype)shared {
    static POSplitXSettings *settings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ settings = [POSplitXSettings new]; });
    return settings;
}

- (instancetype)init {
    if ((self = [super init])) {
        _values = [NSMutableDictionary dictionary];
        [self reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)self, PXSettingsChanged,
                                        CFSTR("com.niubiprass.splitx.settings-changed"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    return self;
}

- (void)reload {
    NSDictionary *before = [_values copy];
    [_values removeAllObjects];
    NSDictionary *stored = [PXDefaults() dictionaryRepresentation];
    for (NSString *key in PXAllowedKeys()) {
        id value = stored[key];
        if (value) _values[key] = value;
    }
    for (NSString *key in PXAllowedKeys()) {
        id old = before[key] ?: @"(空)";
        id now = _values[key] ?: @"(空)";
        if (![old isEqual:now]) {
            PXLog(@"prefs", @"changed %@: %@ -> %@", key, old, now);
        }
    }
    PXLog(@"prefs", @"reload keys=%lu", (unsigned long)_values.count);
}

- (CGFloat)doubleForKey:(NSString *)key fallback:(CGFloat)fallback min:(CGFloat)min max:(CGFloat)max {
    id raw = _values[key];
    if (![raw respondsToSelector:@selector(doubleValue)]) return fallback;
    CGFloat v = [raw doubleValue];
    return MIN(MAX(v, min), max);
}

- (CGFloat)iconSize { return [self doubleForKey:@"iconSize" fallback:60 min:40 max:76]; }
- (CGFloat)tileSize { return [self doubleForKey:@"tileSize" fallback:68 min:52 max:92]; }
- (CGFloat)itemSpacing { return [self doubleForKey:@"itemSpacing" fallback:6 min:0 max:20]; }
- (CGFloat)panelRadius { return [self doubleForKey:@"panelRadius" fallback:30 min:12 max:40]; }
- (CGFloat)panelAlpha { return [self doubleForKey:@"panelAlpha" fallback:0 min:0 max:100] / 100.0; }
- (NSInteger)panelColumns { return (NSInteger)[self doubleForKey:@"panelColumns" fallback:2 min:1 max:3]; }
- (CGFloat)fanRadius { return [self doubleForKey:@"fanRadius" fallback:210 min:120 max:260]; }
- (CGFloat)fanSpan { return [self doubleForKey:@"fanSpan" fallback:120 min:60 max:200]; }
- (CGFloat)animationSpeed { return [self doubleForKey:@"animationSpeed" fallback:100 min:50 max:200]; }
- (BOOL)handleHidden { id v = _values[@"handleHidden"]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO; }
- (CGFloat)handleOpacity { return [self doubleForKey:@"handleOpacity" fallback:100 min:10 max:100] / 100.0; }
- (BOOL)handleAlwaysVisible { id v = _values[@"handleAlwaysVisible"]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : YES; }
- (BOOL)hapticFeedback { id v = _values[@"hapticFeedback"]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : YES; }
- (BOOL)portraitExternalKeyboard { id v=_values[@"portraitExternalKeyboard"]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : YES; }
- (BOOL)landscapeExternalKeyboard { id v=_values[@"landscapeExternalKeyboard"]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO; }
- (BOOL)closeOutsideWithKeyboard { id v=_values[@"closeOutsideWithKeyboard"]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : YES; }
- (CGFloat)internalKeyboardZoomPercent { return [self doubleForKey:@"internalKeyboardZoomPercent" fallback:160 min:100 max:200]; }
- (CGFloat)externalKeyboardHorizontalPercent { return [self doubleForKey:@"externalKeyboardHorizontalPercent" fallback:50 min:0 max:100]; }
- (CGFloat)keyboardDimOpacity { return [self doubleForKey:@"keyboardDimOpacity" fallback:12 min:0 max:60] / 100.0; }
- (BOOL)cloneEnabled { id v = _values[@"cloneEnabled"]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : YES; }
- (BOOL)cloneShowDefault { id v = _values[@"cloneShowDefault"]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : YES; }
- (BOOL)squareIcons { id v = _values[@"squareIcons"]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO; }
- (NSInteger)ring1 { return (NSInteger)[self doubleForKey:@"ring1" fallback:7 min:0 max:12]; }
- (NSInteger)ring2 { return (NSInteger)[self doubleForKey:@"ring2" fallback:10 min:0 max:16]; }
- (NSInteger)ring3 { return (NSInteger)[self doubleForKey:@"ring3" fallback:13 min:0 max:20]; }
- (NSInteger)ring4 { return (NSInteger)[self doubleForKey:@"ring4" fallback:16 min:0 max:24]; }
- (CGFloat)ringGap { return [self doubleForKey:@"ringGap" fallback:0 min:0 max:40]; }
- (CGFloat)handleSlideDistance { return [self doubleForKey:@"handleSlideDistance" fallback:45 min:10 max:120]; }
- (CGFloat)panelEdgeInset { return [self doubleForKey:@"panelEdgeInset" fallback:0 min:0 max:60]; }
- (CGFloat)topGestureWidth { return [self doubleForKey:@"topGestureWidth" fallback:190 min:80 max:300]; }
- (CGFloat)topGestureHeight { return [self doubleForKey:@"topGestureHeight" fallback:50 min:24 max:100]; }
- (CGFloat)topGestureOffset { return [self doubleForKey:@"topGestureOffset" fallback:-20 min:-120 max:120]; }
- (CGFloat)bottomGestureWidth { return [self doubleForKey:@"bottomGestureWidth" fallback:230 min:120 max:360]; }
- (CGFloat)bottomGestureHeight { return [self doubleForKey:@"bottomGestureHeight" fallback:36 min:20 max:80]; }
- (CGFloat)bottomGestureOffset { return [self doubleForKey:@"bottomGestureOffset" fallback:-20 min:-120 max:120]; }
- (BOOL)showGestureArea { id v = _values[@"showGestureArea"]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO; }
- (CGFloat)windowWidthPercent { return [self doubleForKey:@"windowWidthPercent" fallback:62 min:40 max:100]; }
- (CGFloat)windowInset { return [self doubleForKey:@"windowInset" fallback:12 min:0 max:40]; }
- (CGFloat)windowInsetLandscape { return [self doubleForKey:@"windowInsetLandscape" fallback:12 min:0 max:60]; }
- (CGFloat)windowWidthLandscape { return [self doubleForKey:@"windowWidthLandscape" fallback:80 min:40 max:100]; }
- (CGFloat)windowCornerRadiusLandscape { return [self doubleForKey:@"windowCornerRadiusLandscape" fallback:42 min:0 max:60]; }
- (CGFloat)windowMaxScalePercent { return [self doubleForKey:@"windowMaxScalePercent" fallback:172 min:100 max:200]; }
- (CGFloat)windowCornerRadius { return [self doubleForKey:@"windowCornerRadius" fallback:42 min:0 max:60]; }
- (CGFloat)windowShadowStrength { return [self doubleForKey:@"windowShadowStrength" fallback:41 min:0 max:100] / 100.0; }
- (CGFloat)windowShadowBlur { return [self doubleForKey:@"windowShadowBlur" fallback:15 min:0 max:40]; }
- (BOOL)dockNewSplitPushesCurrent { id v = _values[@"dockNewSplitPushesCurrent"]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : YES; }
- (CGFloat)dockWidthPortrait { return [self doubleForKey:@"dockWidthPortrait" fallback:56 min:40 max:120]; }
- (CGFloat)dockWidthLandscape { return [self doubleForKey:@"dockWidthLandscape" fallback:151 min:80 max:220]; }
- (CGFloat)dockAutoStashSeconds { return [self doubleForKey:@"dockAutoStashSeconds" fallback:0 min:0 max:30]; }
- (NSInteger)dockMaxCount { return (NSInteger)[self doubleForKey:@"dockMaxCount" fallback:6 min:2 max:8]; }
- (NSString *)bottomActionForKey:(NSString *)key {
    id v = _values[key];
    return [v isKindOfClass:NSString.class] && [v length] ? v : @"none";
}
- (CGFloat)triggerWidth { return [self doubleForKey:@"triggerWidth" fallback:30 min:8 max:60]; }
- (CGFloat)triggerOffsetY { return [self doubleForKey:@"triggerOffsetY" fallback:0 min:-200 max:200]; }
- (CGFloat)dockScale { return [self doubleForKey:@"dockScale" fallback:0.28 min:0.2 max:0.5]; }

- (BOOL)dockEnabled {
    id raw = _values[@"dockEnabled"];
    return [raw respondsToSelector:@selector(boolValue)] ? [raw boolValue] : YES;
}

- (void)setValue:(id)value forKey:(NSString *)key {
    if (![PXAllowedKeys() containsObject:key]) {
        PXLog(@"prefs", @"reject unknown key=%@", key);
        return;
    }
    _values[key] = value;
    [PXDefaults() setObject:value forKey:key];
    [PXDefaults() synchronize];
    PXLog(@"prefs", @"set %@=%@", key, value);
}

- (NSDictionary<NSString *, id> *)allValues {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *key in PXAllowedKeys()) {
        id value = _values[key];
        if (value) out[key] = value;
    }
    return out;
}

#pragma mark - 期望容器

- (void)setExpectedContainer:(NSString *)container forBundleIdentifier:(NSString *)bundle {
    if (bundle.length == 0) return;
    NSString *key = [@"expectedContainer." stringByAppendingString:bundle];
    if (container.length) {
        [PXDefaults() setObject:container forKey:key];
    } else {
        [PXDefaults() removeObjectForKey:key];
    }
    [PXDefaults() synchronize];
    PXLog(@"route", @"expected %@ -> %@", bundle, container ?: @"(clear)");
}

- (NSString *)expectedContainerForBundleIdentifier:(NSString *)bundle {
    if (bundle.length == 0) return nil;
    id value = [PXDefaults() objectForKey:[@"expectedContainer." stringByAppendingString:bundle]];
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

- (BOOL)exportBackupToPath:(NSString *)path error:(NSError **)error {
    NSDictionary *payload = @{@"version": @1, @"exportedAt": NSDate.date, @"values": [self allValues]};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:payload
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0 error:error];
    if (!data) { PXLog(@"backup", @"export failed %@", *error); return NO; }
    BOOL ok = [data writeToFile:path atomically:YES];
    PXLog(@"backup", @"export %@ ok=%d bytes=%lu", path, ok, (unsigned long)data.length);
    if (!ok && error) *error = [NSError errorWithDomain:PXDomain code:2 userInfo:nil];
    return ok;
}

- (BOOL)importBackupFromPath:(NSString *)path error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        PXLog(@"backup", @"import missing file %@", path);
        if (error) *error = [NSError errorWithDomain:PXDomain code:3 userInfo:nil];
        return NO;
    }
    NSDictionary *payload = [NSPropertyListSerialization propertyListWithData:data
                                                                     options:NSPropertyListImmutable
                                                                      format:NULL error:error];
    NSDictionary *values = [payload isKindOfClass:NSDictionary.class] ? payload[@"values"] : nil;
    if (![values isKindOfClass:NSDictionary.class]) {
        PXLog(@"backup", @"import invalid payload");
        if (error) *error = [NSError errorWithDomain:PXDomain code:4 userInfo:nil];
        return NO;
    }
    NSUInteger applied = 0;
    for (NSString *key in PXAllowedKeys()) {
        id value = values[key];
        if (!value) continue;
        [self setValue:value forKey:key];
        applied++;
    }
    PXLog(@"backup", @"import applied=%lu", (unsigned long)applied);
    return applied > 0;
}

@end

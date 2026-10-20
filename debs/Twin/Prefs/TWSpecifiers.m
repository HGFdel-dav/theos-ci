// TWSpecifiers.m
#import "TWSpecifiers.h"
#import "TWPath.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

NSString *const TWPrefsBundleName = @"TwinPrefs";

// 0.9.0：图标 cell 动态子类工厂（TWIconCells.m）
extern Class TWIconCellClass(NSString *baseClassName);
extern Class TWSliderCellClass(void);

// PSSpecifier 的 setCellClass: 属于 Preferences 私有 API，这里只补签名给编译器看。
@interface NSObject (TWCellClassSetter)
- (void)setCellClass:(Class)cellClass;
@end

// 转发给 PSListController 自己的 detail 分发（私有方法，需 objc_msgSendSuper 绕过头文件）
id TWSuperControllerForSpecifier(id host, id specifier) {
    if (!host || !specifier) return nil;
    Class cls = NSClassFromString(@"PSListController");
    SEL sel = NSSelectorFromString(@"controllerForSpecifier:");
    if (!cls || ![cls instancesRespondToSelector:sel]) return nil;
    struct objc_super sup = { host, cls };
    id (*fn)(struct objc_super *, SEL, id) = (id (*)(struct objc_super *, SEL, id))objc_msgSendSuper;
    return fn(&sup, sel, specifier);
}

#pragma mark - specifier 构造

PSSpecifier *TWGroupSpecifier(NSString *name, NSString *footer) {
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:name ?: @""];
    if (footer.length) [group setProperty:footer forKey:@"footerText"];
    return group;
}

UIColor *TWIconTintColor(NSInteger idx) {
    if (@available(iOS 13.0, *)) {
        NSArray<UIColor *> *palette = @[
            UIColor.systemBlueColor, UIColor.systemRedColor, UIColor.systemGreenColor,
            UIColor.systemOrangeColor, UIColor.systemPurpleColor, UIColor.systemPinkColor,
            UIColor.systemTealColor, UIColor.systemIndigoColor, UIColor.systemBrownColor,
            UIColor.systemGrayColor
        ];
        if (idx >= 0 && idx < (NSInteger)palette.count) return palette[(NSUInteger)idx];
    }
    return nil;
}

PSSpecifier *TWRowSpecifier(id target,
                            NSString *title,
                            NSString *key,
                            id defaultValue,
                            NSString * __unused cellName,
                            PSCellType cellType,
                            NSString *symbol,
                            NSString *controllerClass,
                            NSDictionary *extras) {
    // ★ 0.4.3 定案：全面回归纯标准行。绝不设置 cellClass——自绘 cell（裸 PSTableCell
    //   子类）没有系统控制 cell 的值链 API，PSListController 建 cell 时发的私有消息
    //   它们不响应 → 0.4.0 崩、0.4.1 崩、0.4.2 白屏（开关行能显示 = 唯一没挂自绘
    //   cellClass 的行）。现在所有行一律用系统类渲染：PSSwitchCell / PSSegmentCell /
    //   PSSliderCell / PSLinkCell / PSButtonCell / PSStaticTextCell。
    //   cellName 参数保留仅为不惊动调用点，内容一律忽略。
    //   值链：所有行接标准 set:/get:；需要特殊取值/写值的行（如 ARC 四角掩码）
    //   用 extras 的 twGet/twSet 指定控制器上的自定义选择子（标准机制）。
    // 0.9.12：PSSegmentCell 在本机渲染成整行空白（0.9.11 截图实证）。
    // ScreenCore 原版对这类"多选一"用的是 plist 驱动的 PSStaticTextCell/PSLinkListCell，
    // 点进去再选。这里改成同款：PSLinkListCell + PSListItemsController，
    // 值直接显示在行尾，不依赖分段控件。
    BOOL twIsChoiceRow = (cellType == PSSegmentCell);
    if (twIsChoiceRow) cellType = PSLinkListCell;

    SEL setSel = @selector(setPreferenceValue:specifier:);   // 与各控制器里实现的签名一致
    SEL getSel = @selector(readPreferenceValue:);
    if ([extras[@"twGet"] isKindOfClass:NSString.class] && [extras[@"twGet"] length]) {
        getSel = NSSelectorFromString(extras[@"twGet"]);
    }
    if ([extras[@"twSet"] isKindOfClass:NSString.class] && [extras[@"twSet"] length]) {
        setSel = NSSelectorFromString(extras[@"twSet"]);
    }

    // detail 一律先给 nil，链接行在下面统一按"类名字符串"补上，
    // 保证 name(labels)/key/cellClass/detail/bundle/isController 相互一致。
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title
                                                      target:target
                                                         set:setSel
                                                         get:getSel
                                                      detail:nil
                                                        cell:cellType
                                                        edit:NULL];
    if (!spec) return nil;
    if (twIsChoiceRow) {
        [spec setProperty:@"PSListItemsController" forKey:@"detail"];
        [spec setProperty:@YES forKey:@"isController"];
    }
    if (key.length) [spec setProperty:key forKey:@"key"];
    if (defaultValue) [spec setProperty:defaultValue forKey:@"default"];
    // 0.9.0：图标 cell = 动态子类化系统 cell 类。
    //   基类按 cellType 定：PSSwitchCell / PSLinkCell / PSSliderCell / PSSegmentCell /
    //   PSButtonCell / PSStaticTextCell；为它创建子类 TWIcon_<base>，只覆盖
    //   layoutSubviews 加 27pt 彩色圆角图标并右移文本。开关/滑块/值链全部继承父类，
    //   0.4.x 的崩溃根因（直接继承 PSTableCell 不响应 PSListController 私有消息）不会复现。
    //   没有 symbol 的行保持原系统类，一个字节都不碰。
    // 滑杆行：系统默认 44pt 放不下"标题 + 滑杆"，会叠在一起（实机截图）。
    // 统一给它 78pt，TWStyleSliderCellIfNeeded 再按这个高度排版。
    if (cellType == PSSliderCell && ![spec propertyForKey:@"height"]) {
        [spec setProperty:@78 forKey:@"height"];
    }
    if (symbol.length) {
        [spec setProperty:symbol forKey:@"twSymbol"];
        [spec setProperty:title forKey:@"twTitle"];
        // 滑块行不套图标子类：PSSliderCell 的私有布局一旦被覆盖，标题会被挤出
        // 可视区（0.9.2 实测整行只剩一根滑杆）。滑块保持系统原样渲染。
        // 0.9.3：图标子类在本机完全没生效（cellClass 没被 PSListController 采用，
        // 且套到滑块上还会挤掉标题）。先整体关闭，面板回归系统原样渲染，
        // 保证文字/开关/数值全部正确；图标另起一版用独立 cell 实现。
        BOOL skipIconClass = YES;
        NSString *baseName = nil;
        switch (cellType) {
            case PSSwitchCell:     baseName = @"PSSwitchCell"; break;
            case PSLinkCell:       baseName = @"PSLinkCell"; break;
            case PSSliderCell:     baseName = @"PSSliderCell"; break;
            case PSSegmentCell:    baseName = @"PSSegmentCell"; break;
            case PSButtonCell:     baseName = @"PSButtonCell"; break;
            case PSStaticTextCell: baseName = @"PSStaticTextCell"; break;
            default: break;
        }
        Class iconCls = (baseName && !skipIconClass) ? TWIconCellClass(baseName) : Nil;
        if (cellType == PSSliderCell) {
            Class sliderCls = TWSliderCellClass();
            if (sliderCls) {
                if ([spec respondsToSelector:NSSelectorFromString(@"setCellClass:")]) [spec setCellClass:sliderCls];
                [spec setProperty:NSStringFromClass(sliderCls) forKey:@"cellClass"];
            }
        }
        if (iconCls) {
            // 两条路都铺：PSSpecifier 若有 setCellClass: 就直传 Class（最可靠），
            // 同时写 cellClass 字符串属性——plist 版 specifier 就是按字符串
            // NSClassFromString 解析的，两种实现都覆盖到。
            if ([spec respondsToSelector:NSSelectorFromString(@"setCellClass:")]) {
                [spec setCellClass:iconCls];
            }
            [spec setProperty:NSStringFromClass(iconCls) forKey:@"cellClass"];
        }
    }
    if (controllerClass.length) {
        // 跨 bundle 行（原版 ParallelXPrefs 的 Swift 页）：只写 detail + bundle，
        // 不写 twController。否则第一次进过页面后 bundle 已加载，我们的
        // TWControllerForSpecifier 会直接 alloc 出一个没带 id 的控制器，
        // 打开的就是错页。交给 stock 的 controllerForSpecifier: 走 bundle + id。
        BOOL crossBundle = [extras[@"twBundle"] isKindOfClass:NSString.class] && [extras[@"twBundle"] length];
        if (!crossBundle) {
            [spec setProperty:controllerClass forKey:@"twController"];  // 我们自己 new
        }
        [spec setProperty:controllerClass forKey:@"detail"];        // stock 兜底
        if (!crossBundle) [spec setProperty:TWPrefsBundleName forKey:@"bundle"];      // 与入口 plist 一致
        [spec setProperty:@YES forKey:@"isController"];
    }
    for (NSString *extraKey in extras) {
        id v = extras[extraKey];
        // 系统分段/滑杆读的是 specifier 上的标准键，把自绘键映射过去：
        if ([extraKey isEqualToString:@"twTitles"] && [v isKindOfClass:NSArray.class]) {
            NSMutableArray *idx = [NSMutableArray arrayWithCapacity:[v count]];
            for (NSUInteger i = 0; i < [v count]; i++) [idx addObject:@(i)];
            // 0.9.12：iOS 15 的 PSSegmentCell 在不同版本读的键不一样，
            // 只给 validTitles/validValues 会渲染成一整行空白（0.9.11 实测）。
            // 四组键全写上，总有一组能命中。
            [spec setProperty:v forKey:@"validTitles"];
            [spec setProperty:idx forKey:@"validValues"];
            [spec setProperty:v forKey:@"titles"];
            [spec setProperty:idx forKey:@"values"];
        } else if ([extraKey isEqualToString:@"twMin"]) {
            [spec setProperty:v forKey:@"min"];
            [spec setProperty:v forKey:@"minimum"];
        } else if ([extraKey isEqualToString:@"twBundle"]) {
            // 链接行指向别的 PreferenceBundle 时（原版 ParallelXPrefs 的 Swift 页），
            // 必须把 bundle 换成目标 bundle 名，stock 的 controllerForSpecifier: 才会
            // 去那个 bundle 里找 detail 类。
            [spec setProperty:v forKey:@"bundle"];
            continue;
        } else if ([extraKey isEqualToString:@"twMax"]) {
            [spec setProperty:v forKey:@"max"];
            [spec setProperty:v forKey:@"maximum"];
        }
        [spec setProperty:v forKey:extraKey];
    }
    return spec;
}

PSSpecifier *TWLinkRowSpecifier(id target,
                                NSString *title,
                                NSString *symbol,
                                NSString *controllerClass,
                                NSString *detailText,
                                NSDictionary *extras) {
    NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:extras ?: @{}];
    all[@"height"] = all[@"height"] ?: @56;
    if (detailText.length) all[@"twDetail"] = detailText;
    PSSpecifier *spec = TWRowSpecifier(target, title, nil, nil, nil, PSLinkCell,
                                       symbol, controllerClass, all);
    [spec setProperty:@YES forKey:@"twLink"];
    [spec setProperty:detailText ?: @"" forKey:@"detailText"];  // 系统链接行标准副标题键
    return spec;
}

PSSpecifier *TWButtonRowSpecifier(id target,
                                  NSString *title,
                                  NSString *action,
                                  NSString *symbol,
                                  BOOL destructive,
                                  NSDictionary *extras) {
    NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:extras ?: @{}];
    all[@"height"] = all[@"height"] ?: @56;
    if (destructive) all[@"twDestructive"] = @YES;
    all[@"twAction"] = action ?: @"";
    PSSpecifier *spec = TWRowSpecifier(target, title, nil, nil, nil, PSButtonCell, symbol, nil, all);
    // 标准按钮行：PSButtonCell 点击回调走 buttonAction（0.4.3 起不用自绘 TWActionCell）
    if (action.length) [spec setButtonAction:NSSelectorFromString(action)];
    return spec;
}

id TWControllerForSpecifier(PSListController *host, PSSpecifier *specifier) {
    if (!specifier) return nil;
    // 指向别的 bundle 的行（原版 ParallelXPrefs 的 Swift 页）一律交回 stock 分发：
    // 它要按 bundle + id 组装控制器；我们这里 alloc 出来的实例没有 id，会开错页。
    NSString *ownerBundle = [specifier propertyForKey:@"bundle"];
    if ([ownerBundle isKindOfClass:NSString.class] && ownerBundle.length &&
        ![ownerBundle isEqualToString:TWPrefsBundleName]) {
        return nil;
    }
    NSString *className = [specifier propertyForKey:@"twController"];
    if (![className isKindOfClass:NSString.class] || !className.length) {
        className = [specifier propertyForKey:@"detail"];
    }
    if ([className isKindOfClass:NSString.class] && className.length) {
        Class cls = NSClassFromString(className);
        if (cls) {
            // PSListController 的子页必须走 initForContentSize:（Preferences 就是这么建的）。
            // 直接 [[alloc] init] 出来的实例没有建好 table，推入后是一整页黑的（实机现象）。
            id controller = nil;
            SEL sizeSel = NSSelectorFromString(@"initForContentSize:");
            if ([cls instancesRespondToSelector:sizeSel]) {
                CGSize size = host.view.bounds.size;
                if (size.width < 1) size = CGSizeMake(390, 844);
                controller = ((id (*)(id, SEL, CGSize))objc_msgSend)([cls alloc], sizeSel, size);
            } else {
                controller = [[cls alloc] init];
            }
            if ([controller isKindOfClass:UIViewController.class]) {
                // 0.7.0：ParallelX 透传子页共用一个控制器，用 twPXPage 区分页面类型。
                id page = [specifier propertyForKey:@"twPXPage"];
                if ([page isKindOfClass:NSNumber.class] && [controller respondsToSelector:@selector(setPageType:)]) {
                    ((void (*)(id, SEL, long))objc_msgSend)(controller, @selector(setPageType:), (long)[page integerValue]);
                }
                return controller;
            }
        }
    }
    return nil;
}

#pragma mark - 符号查找（TWRemember 由并行任务提供，可能不在本进程）

static void *TWSymbolVoid(const char *name) {
    void *sym = dlsym(RTLD_DEFAULT, name);
#ifndef RTLD_SELF
#define RTLD_SELF ((void *)-3)
#endif
#ifndef RTLD_MAIN_ONLY
#define RTLD_MAIN_ONLY ((void *)-5)
#endif
    if (!sym) sym = dlsym(RTLD_SELF, name);
    if (!sym) sym = dlsym(RTLD_MAIN_ONLY, name);
    return sym;
}

#pragma mark - 记忆（形态快照）

static NSString *TWRectText(id frame) {
    if (![frame isKindOfClass:NSDictionary.class]) return nil;
    NSNumber *x = frame[@"x"], *y = frame[@"y"], *w = frame[@"w"], *h = frame[@"h"];
    if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class] ||
        ![w isKindOfClass:NSNumber.class] || ![h isKindOfClass:NSNumber.class]) return nil;
    return [NSString stringWithFormat:@"%.0f×%.0f @ (%.0f, %.0f)",
            w.doubleValue, h.doubleValue, x.doubleValue, y.doubleValue];
}

// 与 TWRemember.m 的字段约定一致：p=竖屏 frame，l=横屏 frame，docked/side=形态。
static NSString *TWStateSummary(NSString *containerID, NSDictionary *state) {
    NSMutableArray *bits = [NSMutableArray array];
    [bits addObject:containerID.length ? [NSString stringWithFormat:@"容器 %@", containerID] : @"默认容器"];
    NSString *portrait = TWRectText(state[@"p"]);
    NSString *landscape = TWRectText(state[@"l"]);
    if (portrait) [bits addObject:[NSString stringWithFormat:@"竖 %@", portrait]];
    if (landscape) [bits addObject:[NSString stringWithFormat:@"横 %@", landscape]];
    id dockedValue = state[@"docked"];
    BOOL docked = [dockedValue respondsToSelector:@selector(boolValue)] && [dockedValue boolValue];
    if (docked) {
        id sideValue = state[@"side"];
        NSInteger side = [sideValue respondsToSelector:@selector(integerValue)] ? [sideValue integerValue] : 0;
        [bits addObject:(side == 1 ? @"缩小态 · 贴右" : @"缩小态 · 贴左")];
    }
    if (!portrait && !landscape && !docked) [bits addObject:@"尚无形态记录"];
    return [bits componentsJoinedByString:@" · "];
}

static NSArray<NSDictionary *> *TWRememberStatesFromPrefs(void) {
    id raw = [[TWPrefs shared] objectForKey:TWKeyRememberStates];
    if (![raw isKindOfClass:NSDictionary.class]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id keyObject in raw) {
        if (![keyObject isKindOfClass:NSString.class] || ![keyObject length]) continue;
        NSDictionary *state = raw[keyObject];
        if (![state isKindOfClass:NSDictionary.class]) continue;
        NSString *entryKey = keyObject;
        NSArray<NSString *> *parts = [entryKey componentsSeparatedByString:@"|"];
        NSString *bundleID = parts.count > 0 ? parts[0] : entryKey;
        NSString *containerID = parts.count > 1 ? parts[1] : @"";
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"key"] = entryKey;
        entry[@"bundleID"] = bundleID;
        entry[@"containerID"] = containerID;
        entry[@"summary"] = TWStateSummary(containerID, state);
        for (NSString *field in @[@"p", @"l", @"docked", @"side", @"updated"]) {
            if (state[field]) entry[field] = state[field];
        }
        [out addObject:entry];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"key"] localizedStandardCompare:b[@"key"]];
    }];
    return out;
}

NSArray<NSDictionary *> *TWRememberSnapshot(void) {
    typedef NSArray<NSDictionary *> *(*TWAllStatesFn)(void);
    TWAllStatesFn allStates = (TWAllStatesFn)TWSymbolVoid("TWRememberAllStates");
    if (allStates) {
        NSArray *states = allStates();
        if ([states isKindOfClass:NSArray.class]) return states;
    }
    return TWRememberStatesFromPrefs();
}

NSInteger TWRememberSnapshotCount(void) {
    return (NSInteger)TWRememberSnapshot().count;
}

BOOL TWRememberDeleteState(NSString *key) {
    if (!key.length) return NO;
    NSMutableDictionary *all = [[[TWPrefs shared] objectForKey:TWKeyRememberStates] mutableCopy];
    if (!all) return NO;
    [all removeObjectForKey:key];
    [[TWPrefs shared] setObject:(all.count ? all : nil) forKey:TWKeyRememberStates];

    // 旧格式（整窗 frame）按 bundleID 同步清掉，避免两套记忆互相打架。
    NSArray<NSString *> *parts = [key componentsSeparatedByString:@"|"];
    NSString *bundleID = parts.count ? parts[0] : nil;
    if (bundleID.length) {
        NSMutableDictionary *legacy = [[[TWPrefs shared] objectForKey:TWKeyRememberFrames] mutableCopy];
        if (legacy[bundleID]) {
            [legacy removeObjectForKey:bundleID];
            [[TWPrefs shared] setObject:(legacy.count ? legacy : nil) forKey:TWKeyRememberFrames];
        }
    }
    [[TWPrefs shared] synchronize];
    return YES;
}

void TWRememberWipe(void) {
    typedef void (*TWResetFn)(void);
    TWResetFn reset = (TWResetFn)TWSymbolVoid("TWRememberResetAll");
    if (reset) reset();
    // 无论 `TWRememberAllStates/TWRememberResetAll` 在不在，都把偏好文件里的两套
    // 记忆清干净（TWPrefs 只写 jbroot 私有 plist，不碰真实 Preferences）。
    [[TWPrefs shared] setObject:nil forKey:TWKeyRememberStates];
    [[TWPrefs shared] setObject:nil forKey:TWKeyRememberFrames];
    [[TWPrefs shared] synchronize];
}

#pragma mark - 分身（容器）/ Arc 顺序

NSArray<NSDictionary *> *TWCraneContainers(void) {
    id raw = [[TWPrefs shared] objectForKey:TWKeyCraneContainers];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    if ([raw isKindOfClass:NSArray.class]) {
        for (id item in raw) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            NSString *bundleID = item[@"bundleID"];
            if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) continue;
            NSString *containerID = [item[@"containerID"] isKindOfClass:NSString.class] ? item[@"containerID"] : @"";
            NSString *identity = [NSString stringWithFormat:@"%@|%@", bundleID, containerID];
            if ([seen containsObject:identity]) continue;
            [seen addObject:identity];
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            entry[@"bundleID"] = bundleID;
            entry[@"containerID"] = containerID;
            entry[@"name"] = [item[@"name"] isKindOfClass:NSString.class] ? item[@"name"] : TWPrefsAppName(bundleID);
            NSString *badge = [item[@"badge"] isKindOfClass:NSString.class] ? item[@"badge"] : nil;
            entry[@"badge"] = badge.length ? badge : (containerID.length ? @"分" : @"默");
            id enabled = item[@"enabled"];
            entry[@"enabled"] = [enabled respondsToSelector:@selector(boolValue)] ? @([enabled boolValue]) : @YES;
            [out addObject:entry];
        }
    }
    // 0.3.x 的 { bundleID : containerID } 映射继续兼容显示。
    NSDictionary<NSString *, NSString *> *legacy = [[TWPrefs shared] craneApps];
    for (NSString *bundleID in legacy) {
        NSString *containerID = legacy[bundleID];
        NSString *identity = [NSString stringWithFormat:@"%@|%@", bundleID, containerID];
        if ([seen containsObject:identity]) continue;
        [seen addObject:identity];
        [out addObject:@{@"bundleID": bundleID,
                         @"containerID": containerID ?: @"",
                         @"name": TWPrefsAppName(bundleID),
                         @"badge": @"分",
                         @"enabled": @YES}];
    }
    return out;
}

NSInteger TWCraneContainerCount(void) {
    return (NSInteger)TWCraneContainers().count;
}

NSArray<NSString *> *TWArcOrderList(void) {
    id raw = [[TWPrefs shared] objectForKey:TWKeyCraneAppList];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    if ([raw isKindOfClass:NSArray.class]) {
        for (id item in raw) {
            if ([item isKindOfClass:NSString.class] && [item length] && ![order containsObject:item]) [order addObject:item];
        }
    }
    if (order.count) return order;
    // 还没排过顺序：用分身数据（保持稳定顺序）兜底，让用户直接能拖。
    NSMutableArray<NSString *> *seed = [NSMutableArray array];
    for (NSDictionary *entry in TWCraneContainers()) {
        NSString *bundleID = entry[@"bundleID"];
        if (bundleID.length && ![seed containsObject:bundleID]) [seed addObject:bundleID];
    }
    if (!seed.count) {
        NSArray<NSString *> *legacyKeys = [[[TWPrefs shared] craneApps] allKeys];
        seed = [[legacyKeys sortedArrayUsingSelector:@selector(compare:)] mutableCopy];
    }
    return seed;
}

void TWSetArcOrderList(NSArray<NSString *> *list) {
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (id item in list) {
        if ([item isKindOfClass:NSString.class] && [item length] && ![clean containsObject:item]) [clean addObject:item];
    }
    [[TWPrefs shared] setObject:(clean.count ? clean : nil) forKey:TWKeyCraneAppList];
    [[TWPrefs shared] synchronize];
}

#pragma mark - 应用名

NSString *TWPrefsAppName(NSString *bundleID) {
    if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) return @"";
    // arm64e 上绝不能把 objc_msgSend 转成可变参数函数指针——PAC 会失效，
    // 表现为 EXC_BAD_ACCESS / “possible pointer authentication failure”。
    // 一律用精确签名，并整体 @try 兜底。
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    if (proxyCls) {
        @try {
            SEL proxySel = NSSelectorFromString(@"applicationProxyForIdentifier:");
            if ([proxyCls respondsToSelector:proxySel]) {
                id (*makeProxy)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
                id proxy = makeProxy(proxyCls, proxySel, bundleID);
                if (proxy) {
                    SEL nameSel = NSSelectorFromString(@"localizedName");
                    if ([proxy respondsToSelector:nameSel]) {
                        id (*getName)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                        id name = getName(proxy, nameSel);
                        if ([name isKindOfClass:NSString.class] && [name length]) return name;
                    }
                }
            }
        } @catch (__unused NSException *e) {}
    }
    return bundleID;
}

#pragma mark - 诊断（0.4.3 观测版）：异常原文 + 构建轨迹落盘（沙盒内）

// ★ 必须保证可写：0.4.2 写真实 /var/mobile/Documents（沙盒挡）、0.4.3 写容器 Documents
//   （设备上也未见落盘）→ 0.4.4 改为主写 jbroot AppGroup 内 Preferences 目录
//   （面板的 TWPrefs 本来就读写这里，已证明可写），root 端从
//   /var/mobile/Containers/Shared/AppGroup/.jbroot-*/var/mobile/Library/Preferences/ 取。
NSString *TWDiagLogPathResolve(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in TWJBRootCandidates()) {
        NSString *prefsDir = [root stringByAppendingPathComponent:@"var/mobile/Library/Preferences"];
        if (![fm fileExistsAtPath:prefsDir]) continue;
        NSString *probe = [prefsDir stringByAppendingPathComponent:@".diag-probe"];
        if ([fm createFileAtPath:probe contents:[NSData dataWithBytes:"x" length:1] attributes:nil]) {
            [fm removeItemAtPath:probe error:nil];
            return [prefsDir stringByAppendingPathComponent:@"TwinPrefs-diagnose.log"];
        }
    }
    // 兜底：应用沙盒 Documents
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count) return [paths[0] stringByAppendingPathComponent:@"TwinPrefs-diagnose.log"];
    return nil;
}

NSString *const TWDiagLogPath = @"TwinPrefs-diagnose.log"; // 实际路径由 Resolve 决定

void TWDiagLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    @try {
        NSString *path = TWDiagLogPathResolve();
        if (!path) return;
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) return;
        [fh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:@"%@ [TwinPrefs] %@\n",
                          [[NSDate date] descriptionWithLocale:[NSLocale currentLocale]], msg];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *ignore) {}
}

void TWDiagDumpException(NSException *e, NSString *context) {
    TWDiagLog(@"==== EXCEPTION context=%@ ====", context ?: @"?");
    TWDiagLog(@"name:   %@", e.name);
    TWDiagLog(@"reason: %@", e.reason);
    TWDiagLog(@"userInfo: %@", e.userInfo);
    TWDiagLog(@"stack:\n%@", [e.callStackSymbols componentsJoinedByString:@"\n"]);
}

static void TWUncaughtHandler(NSException *e) {
    TWDiagDumpException(e, @"UNCAUGHT");
}

__attribute__((constructor))
static void TWDiagInstallUncaughtHandler(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSSetUncaughtExceptionHandler(TWUncaughtHandler);
    });
}

#pragma mark - 滑块行的标题（0.9.6）

// 本机 Preferences 的 PSSliderCell 不画标题（cellClass 动态子类也不生效），
// 所以在 cell 即将显示时直接把标题/数值塞进 cell 自己，并给滑杆让出下半个身位。
// 不改 cell 类、不覆盖任何私有方法，纯加子视图，最坏情况也只是多一个 UILabel。
void TWStyleSliderCellIfNeeded(UITableViewCell *cell, PSSpecifier *specifier) {
    if (![cell isKindOfClass:[UITableViewCell class]] || !specifier) return;
    if ([specifier cellType] != PSSliderCell) return;

    UISlider *slider = nil;
    NSMutableArray *queue = [NSMutableArray arrayWithArray:cell.contentView.subviews ?: @[]];
    [queue addObjectsFromArray:cell.subviews ?: @[]];
    NSInteger guard = 0;
    while (queue.count && guard++ < 200) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UISlider class]]) { slider = (UISlider *)v; break; }
        [queue addObjectsFromArray:v.subviews ?: @[]];
    }
    if (!slider) return;

    UILabel *title = [cell.contentView viewWithTag:0x774C4454];
    UILabel *value = [cell.contentView viewWithTag:0x774C4455];
    CGFloat w = CGRectGetWidth(cell.contentView.bounds);
    if (w <= 0) w = CGRectGetWidth(cell.bounds);

    if (!title) {
        title = [[UILabel alloc] initWithFrame:CGRectMake(16, 7, w - 32, 18)];
        title.tag = 0x774C4454;
        title.font = [UIFont systemFontOfSize:15.0];
        title.textColor = [UIColor labelColor];
        [cell.contentView addSubview:title];

        value = [[UILabel alloc] initWithFrame:CGRectMake(16, 7, w - 32, 18)];
        value.tag = 0x774C4455;
        value.font = [UIFont systemFontOfSize:14.0];
        value.textColor = [UIColor secondaryLabelColor];
        value.textAlignment = NSTextAlignmentRight;
        [cell.contentView addSubview:value];
    }

    NSString *name = specifier.name ?: @"";
    title.text = name;
    NSString *unit = [specifier propertyForKey:@"twUnit"];
    if (![unit isKindOfClass:NSString.class]) unit = @"";
    value.text = [NSString stringWithFormat:@"%.0f%@", slider.value, unit];
    CGFloat h = CGRectGetHeight(cell.bounds);
    if (h < 44) h = 44;
    CGFloat top = (h >= 66) ? 10 : 2;
    title.frame = CGRectMake(16, top, w - 32, 18);
    value.frame = CGRectMake(16, top, w - 32, 18);

    CGFloat sliderH = CGRectGetHeight(slider.bounds);
    if (sliderH <= 0 || sliderH > 40) sliderH = 31;
    // 标题占顶部 18pt，滑杆从 34pt 起；高度不够时把滑杆压到标题下方而不是重叠。
    CGFloat sliderY = (h >= 66) ? 34 : 24;
    if (sliderY + sliderH > h) sliderY = MAX(top + 20, h - sliderH);
    slider.frame = CGRectMake(16, sliderY, MAX(w - 32, 40), sliderH);
}

#pragma mark - 行图标（0.9.7：不依赖 cellClass，直接往标准 cell 里塞）

static UIColor *TWDecoTint(NSInteger idx) {
    switch (((idx % 6) + 6) % 6) {
        case 0: return [UIColor systemBlueColor];
        case 1: return [UIColor systemGreenColor];
        case 2: return [UIColor systemPinkColor];
        case 3: return [UIColor systemOrangeColor];
        case 4: return [UIColor systemPurpleColor];
        default: return [UIColor systemTealColor];
    }
}

static UIImage *TWDecoIcon(NSString *symbol, NSInteger colorIdx) {
    if (![symbol isKindOfClass:NSString.class] || !symbol.length) return nil;
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *key = [NSString stringWithFormat:@"%@|%ld", symbol, (long)colorIdx];
    UIImage *hit = cache[key];
    if (hit) return hit;

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    UIImage *glyph = [UIImage systemImageNamed:symbol withConfiguration:cfg];
    if (!glyph) return nil;
    UIImage *white = [glyph imageWithTintColor:UIColor.whiteColor
                                  renderingMode:UIImageRenderingModeAlwaysTemplate];

    CGSize size = CGSizeMake(27, 27);
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 27, 27) cornerRadius:6.5];
        [TWDecoTint(colorIdx) setFill];
        [p fill];
        CGFloat side = 15.0;
        [white drawInRect:CGRectMake((27 - side) / 2, (27 - side) / 2, side, side)
                blendMode:kCGBlendModeNormal alpha:1.0];
    }];
    if (img) cache[key] = img;
    return img;
}

// 标准 cell 上补一个彩色圆角图标，并把标题往右让 38pt。
void TWDecorateCellIfNeeded(UITableViewCell *cell, PSSpecifier *specifier) {
    if (![cell isKindOfClass:[UITableViewCell class]] || !specifier) return;
    NSString *symbol = [specifier propertyForKey:@"twSymbol"];
    if (![symbol isKindOfClass:NSString.class] || !symbol.length) return;

    id colorObj = [specifier propertyForKey:@"twColor"];
    NSInteger colorIdx = [colorObj isKindOfClass:NSNumber.class] ? [colorObj integerValue] : 0;
    UIImage *img = TWDecoIcon(symbol, colorIdx);
    if (!img) return;

    UIImageView *iv = [cell.contentView viewWithTag:0x774C4450];
    if (!iv) {
        iv = [[UIImageView alloc] initWithFrame:CGRectMake(13, 0, 27, 27)];
        iv.tag = 0x774C4450;
        iv.contentMode = UIViewContentModeCenter;
        [cell.contentView addSubview:iv];
    }
    iv.image = img;
    iv.frame = CGRectMake(13, (CGRectGetHeight(cell.contentView.bounds) - 27) / 2.0, 27, 27);

    // 0.9.8：只挪 cell.textLabel 是不够的 —— 滑块行/分段行里真正画标题的是 cell
    // 自己的私有 label（textLabel 为 nil 或不可见），结果就是图标压在文字上
    //（用户原话："图标全部遮住了"）。改成：凡是起点落在图标区（x < 46）且有一定
    // 宽度的子视图，统统右移 38pt 并按同样数值缩短，右边缘保持不变。
    // 已经右移过的（x >= 46）直接跳过，重复调用天然幂等。
    // 0.9.9：按 ParallelX 的做法用「行缩进」给图标让位（它的面板也是靠
    // indentationLevel 实现的）。系统自己的文本布局会把标题右移，
    // 不再依赖手动改 frame —— 0.9.8 实测开关/滑块行的标题根本不动。
    cell.indentationWidth = 38;
    cell.indentationLevel = 1;

    // 兜底：个别 cell 不吃缩进（标题 label 直接挂在 cell 上），
    // 那就把落在图标区的子视图整体右移；已经让开（x>=46）的自动跳过。
    NSMutableArray<UIView *> *candidates = [NSMutableArray arrayWithArray:cell.contentView.subviews];
    for (UIView *sub in cell.subviews) {
        if (sub == cell.contentView) continue;
        [candidates addObject:sub];
    }
    for (UIView *sub in candidates) {
        if (sub == iv || sub == cell.contentView) continue;
        CGRect frame = sub.frame;
        if (frame.size.width < 40 || frame.origin.x >= 46) continue;
        frame.origin.x += 38;
        frame.size.width = MAX(40, frame.size.width - 38);
        sub.frame = frame;
    }
}

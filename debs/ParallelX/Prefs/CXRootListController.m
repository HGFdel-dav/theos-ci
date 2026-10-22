// CXRootListController.m
//
// 「分身」页（嵌在 ParallelX 设置面板里）。
// 容器全部来自分身组件（Crane）：应用在 Crane 里设了几个容器，
// 菜单里就自动出现几个图标（默 / 分），不需要勾选。
// 这里只提供"整个应用不在菜单显示"的开关，默认全开。
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <string.h>
#import "CXCraneBridge.h"
#import "CXPrefs.h"
#import "CXLog.h"

static NSString *CXAppName(NSString *bundleID) {
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    if (proxyCls) {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyCls,
            NSSelectorFromString(@"applicationProxyForIdentifier:"), bundleID);
        if (proxy) {
            id name = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"localizedName"));
            if ([name isKindOfClass:NSString.class] && [name length]) return name;
        }
    }
    return bundleID;
}

@interface CXRootListController : PSListController
@end

@implementation CXRootListController

- (instancetype)init {
    if ((self = [super init])) self.title = @"分身";
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

- (id)readShown:(PSSpecifier *)spec {
    NSString *bundle = [spec propertyForKey:@"cxBundleID"];
    return @([[CXPrefs shared] isAppShownInMenu:bundle]);
}

- (void)writeShown:(id)value specifier:(PSSpecifier *)spec {
    NSString *bundle = [spec propertyForKey:@"cxBundleID"];
    [[CXPrefs shared] setApp:bundle shownInMenu:[value boolValue]];
    CXLog(@"[prefs] %@ shown=%d", bundle, [value boolValue]);
}

- (NSArray<PSSpecifier *> *)specifiers {
    _specifiers = nil;
    NSMutableArray<PSSpecifier *> *specs = [NSMutableArray array];

    PSSpecifier *intro = [PSSpecifier groupSpecifierWithName:@""];
    [intro setProperty:@"容器来自分身组件：应用在分身组件里设了几个容器，分屏菜单里就会自动出现几个图标（默 / 分），无需勾选。关闭某个应用的开关只会让它的分身图标从菜单里消失，不影响分身本身。"
               forKey:@"footerText"];
    [specs addObject:intro];

    if (![CXCraneBridge isCraneAvailable]) {
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"未检测到分身组件"
                                                        target:self set:NULL get:NULL detail:nil
                                                          cell:PSStaticTextCell edit:nil]];
        BOOL springboardOK = [[CXPrefs shared] boolForKey:CXKeyDiagCraneOK defaultValue:NO];
        PSSpecifier *diagGroup = [PSSpecifier groupSpecifierWithName:@"查找记录"];
        [diagGroup setProperty:springboardOK
            ? @"SpringBoard 里已加载分身组件，功能实际可用；只是设置进程里没找到，重启设置应用后再看。"
            : @"以上是设置进程里尝试过的路径。若都显示 ✗，说明这台机器上确实没有装分身组件。"
            forKey:@"footerText"];
        [specs addObject:diagGroup];
        for (NSString *line in [CXCraneBridge diagnosticLines])
            [specs addObject:[PSSpecifier preferenceSpecifierNamed:line
                                                            target:self set:NULL get:NULL detail:nil
                                                              cell:PSStaticTextCell edit:nil]];
        _specifiers = specs;
        return _specifiers;
    }

    NSArray<NSString *> *apps = [CXCraneBridge applicationsWithNonDefaultContainers];
    NSMutableArray<NSString *> *sorted = [apps mutableCopy] ?: [NSMutableArray array];
    [sorted sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [CXAppName(a) localizedStandardCompare:CXAppName(b)];
    }];

    if (!sorted.count) {
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"分身组件里还没有双容器应用"
                                                        target:self set:NULL get:NULL detail:nil
                                                          cell:PSStaticTextCell edit:nil]];
    }
    for (NSString *bundle in sorted) {
        NSArray<NSDictionary *> *containers = [CXCraneBridge containersForBundleID:bundle];
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSDictionary *entry in containers) {
            BOOL isDefault = [entry[@"isDefault"] boolValue];
            NSString *name = entry[@"name"];
            [names addObject:isDefault ? @"默认" : (name.length ? name : entry[@"containerID"])];
        }
        NSString *title = [NSString stringWithFormat:@"%@（%@）", CXAppName(bundle),
                           [names componentsJoinedByString:@" / "]];
        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:title
                                                          target:self
                                                             set:@selector(writeShown:specifier:)
                                                             get:@selector(readShown:)
                                                          detail:nil
                                                            cell:PSSwitchCell
                                                            edit:nil];
        [row setProperty:bundle forKey:@"cxBundleID"];
        [specs addObject:row];
    }

    PSSpecifier *note = [PSSpecifier groupSpecifierWithName:@"说明"];
    [note setProperty:@"切换容器时目标应用会短暂重启，这是分身机制的固有行为。\n若菜单里没看到分身图标，重启一次桌面；仍有问题就把 /var/mobile/Library/Application Support/CloneX/runtime.log 发我。"
               forKey:@"footerText"];
    [specs addObject:note];

    _specifiers = specs;
    return _specifiers;
}

@end
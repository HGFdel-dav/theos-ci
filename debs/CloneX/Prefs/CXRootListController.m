// CXRootListController.m
//
// CloneX 设置根页。
// 列表 = Crane 里存在分身的应用；行标题「应用名 · 当前选中的容器」。
// 点行手动 push 容器选择页（不依赖 detail 自动实例化，参数直接传）。
// 遵守 SplitX/LESSONS.md：不覆写 initForContentSize:，specifiers 一次建好缓存。
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "CXContainerPicker.h"
#import "CXCraneBridge.h"
#import "CXPrefs.h"
#import "CXLog.h"

static NSString *CXAppName(NSString *bundleID) {
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    if (proxyCls) {
        SEL proxySel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyCls, proxySel, bundleID);
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
    if ((self = [super init])) self.title = @"CloneX";
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _specifiers = nil;            // 从选择页回来时刷新容器名
    [self reloadSpecifiers];
}

- (NSArray<PSSpecifier *> *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray<PSSpecifier *> *specs = [NSMutableArray array];

    PSSpecifier *intro = [PSSpecifier groupSpecifierWithName:@""];
    [intro setProperty:@"为应用指定分身容器。之后从分屏菜单点它的图标打开窗口时，会先切到所选分身，再按原样开窗。"
               forKey:@"footerText"];
    [specs addObject:intro];

    if (![CXCraneBridge isCraneAvailable]) {
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"未检测到分身组件"
                                                        target:self set:NULL get:NULL detail:nil
                                                          cell:PSStaticTextCell edit:nil]];
        _specifiers = specs;
        return _specifiers;
    }

    NSArray<NSString *> *craneApps = [CXCraneBridge applicationsWithNonDefaultContainers];
    NSDictionary<NSString *, NSString *> *configured = [CXPrefs shared].cloneApps;
    NSMutableArray<NSString *> *bundleIDs = [NSMutableArray array];
    for (NSString *bundle in craneApps)
        if ([bundle isKindOfClass:NSString.class] && bundle.length && ![bundleIDs containsObject:bundle])
            [bundleIDs addObject:bundle];
    for (NSString *bundle in configured)
        if ([bundle isKindOfClass:NSString.class] && bundle.length && ![bundleIDs containsObject:bundle])
            [bundleIDs addObject:bundle];
    [bundleIDs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [CXAppName(a) localizedStandardCompare:CXAppName(b)];
    }];

    if (!bundleIDs.count) {
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"暂无可用分身"
                                                        target:self set:NULL get:NULL detail:nil
                                                          cell:PSStaticTextCell edit:nil]];
    } else {
        for (NSString *bundle in bundleIDs) {
            NSString *container = configured[bundle];
            NSString *containerName = @"默认容器";
            if (container.length && ![container isEqualToString:@"DEFAULT"]) {
                NSString *name = [CXCraneBridge displayNameForContainer:container bundleID:bundle];
                containerName = name.length ? name : container;
            }
            NSString *title = [NSString stringWithFormat:@"%@ · %@", CXAppName(bundle), containerName];
            PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:title
                                                              target:self set:NULL get:NULL detail:nil
                                                                cell:PSLinkCell edit:nil];
            [row setProperty:bundle forKey:@"cxBundleID"];
            [specs addObject:row];
        }
    }

    PSSpecifier *note = [PSSpecifier groupSpecifierWithName:@"说明"];
    [note setProperty:@"切换容器时目标应用会短暂重启，这是分身机制的固有行为。\n如果打开后仍是原来的数据，请先确认分身组件里这个应用的分身已启用。"
               forKey:@"footerText"];
    [specs addObject:note];

    _specifiers = specs;
    return _specifiers;
}

- (void)openPicker:(PSSpecifier *)spec {
    NSString *bundleID = [spec propertyForKey:@"cxBundleID"];
    if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) return;
    CXContainerPicker *picker = [[CXContainerPicker alloc] initForBundleID:bundleID];
    [self.navigationController pushViewController:picker animated:YES];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if ([spec propertyForKey:@"cxBundleID"]) [self openPicker:spec];
    else [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

@end

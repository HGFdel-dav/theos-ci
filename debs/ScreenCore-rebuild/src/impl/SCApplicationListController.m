#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "../headers/SCApplicationTarget.h"

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
- (NSURL *)bundleURL;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allInstalledApplications;
@end

@interface SCApplicationListController : PSListController
@end

@implementation SCApplicationListController {
    NSArray<LSApplicationProxy *> *_apps;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self loadApplications];
}

- (void)loadApplications {
    Class ws = NSClassFromString(@"LSApplicationWorkspace");
    if (!ws) {
        _apps = @[];
        return;
    }
    
    id workspace = [ws performSelector:@selector(defaultWorkspace)];
    _apps = [workspace performSelector:@selector(allInstalledApplications)];
    
    // 过滤系统应用
    NSPredicate *pred = [NSPredicate predicateWithBlock:^BOOL(LSApplicationProxy *app, NSDictionary *bindings) {
        NSString *bundleID = app.bundleIdentifier;
        if ([bundleID hasPrefix:@"com.apple."]) return NO;
        if ([bundleID isEqualToString:@"com.susudear.screencore"]) return NO;
        return YES;
    }];
    _apps = [_apps filteredArrayUsingPredicate:pred];
    
    // 按名字排序
    _apps = [_apps sortedArrayUsingComparator:^NSComparisonResult(LSApplicationProxy *a, LSApplicationProxy *b) {
        return [a.localizedName compare:b.localizedName options:NSCaseInsensitiveSearch];
    }];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        
        for (LSApplicationProxy *app in _apps) {
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:app.localizedName
                                                               target:self
                                                                  set:NULL
                                                                  get:NULL
                                                               detail:NSClassFromString(@"SCContainerListController")
                                                                 cell:PSLinkCell
                                                                 edit:nil];
            [spec setProperty:app.bundleIdentifier forKey:@"bundleID"];
            [specs addObject:spec];
        }
        
        _specifiers = [specs copy];
    }
    return _specifiers;
}

@end

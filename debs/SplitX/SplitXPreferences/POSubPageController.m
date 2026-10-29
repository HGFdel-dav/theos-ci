#import "POSubPageController.h"
#import "POSplitXLog.h"
#import <objc/message.h>

@implementation POSubPageController {
    NSString *_subPagePlistName;
}

- (instancetype)initWithPlistName:(NSString *)plistName title:(NSString *)title {
    if ((self = [super init])) {
        _subPagePlistName = [plistName copy];
        self.title = title;
        PXLog(@"prefs", @"子页 init plist=%@ title=%@", plistName, title);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    @try {
        // 不指定 bundle 时会去 Preferences.app 里找 plist，找不到就退回上一页的内容。
        NSBundle *own = [NSBundle bundleForClass:[POSubPageController class]];
        SEL setBundle = NSSelectorFromString(@"setBundle:");
        if (own && [self respondsToSelector:setBundle]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self, setBundle, own);
        }
        // PSListController 内部会看 name / bundle，两个都对齐，避免回退到上一页。
        SEL setName = NSSelectorFromString(@"setName:");
        if ([self respondsToSelector:setName]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self, setName, _subPagePlistName);
        }
        PXLog(@"prefs", @"子页 load plist=%@ bundle=%@", _subPagePlistName, own.bundlePath ?: @"nil");
        [self loadSpecifiersFromPlistName:_subPagePlistName target:self];
        PXLog(@"prefs", @"子页 load ok count=%lu", (unsigned long)self.specifiers.count);
    } @catch (NSException *exception) {
        PXLogE(@"prefs", @"子页 load 抛异常 %@: %@", exception.name, exception.reason);
        @throw;
    }
}

@end

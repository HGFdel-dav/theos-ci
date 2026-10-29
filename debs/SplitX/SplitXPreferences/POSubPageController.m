#import "POSubPageController.h"
#import "POSplitXLog.h"

@implementation POSubPageController {
    NSString *_plistName;
}

- (instancetype)initWithPlistName:(NSString *)plistName title:(NSString *)title {
    if ((self = [super init])) {
        _plistName = [plistName copy];
        self.title = title;
        PXLog(@"prefs", @"子页 init plist=%@ title=%@", plistName, title);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    @try {
        PXLog(@"prefs", @"子页 load plist=%@ bundle=%@", _plistName, NSBundle.mainBundle.bundlePath);
        [self loadSpecifiersFromPlistName:_plistName target:self];
        PXLog(@"prefs", @"子页 load ok count=%lu", (unsigned long)self.specifiers.count);
    } @catch (NSException *exception) {
        PXLogE(@"prefs", @"子页 load 抛异常 %@: %@", exception.name, exception.reason);
        @throw;
    }
}

@end

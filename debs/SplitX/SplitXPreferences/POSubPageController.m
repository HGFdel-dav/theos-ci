#import "POSubPageController.h"

@implementation POSubPageController {
    NSString *_plistName;
}

- (instancetype)initWithPlistName:(NSString *)plistName title:(NSString *)title {
    if ((self = [super init])) {
        _plistName = [plistName copy];
        self.title = title;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self loadSpecifiersFromPlistName:_plistName target:self];
}

@end

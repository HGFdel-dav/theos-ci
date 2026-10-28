#import "POApplicationWhitelistController.h"
#import "POSearchPresentation.h"

@interface POApplicationWhitelistController ()
@property (nonatomic) BOOL searchPositionedAtTop;
@end

@implementation POApplicationWhitelistController

- (void)viewDidLoad {
    [super viewDidLoad];
    POConfigureSearchPresentation(self, self.navigationItem.searchController);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    PORevealSearchOnFirstAppearance(self, self.table, &_searchPositionedAtTop);
}

@end

#import <Preferences/PSListController.h>

@interface ATLApplicationListControllerBase : PSListController <UISearchResultsUpdating>
@end

@interface ATLApplicationListMultiSelectionController : ATLApplicationListControllerBase
@end

@interface POApplicationWhitelistController : ATLApplicationListMultiSelectionController
@end

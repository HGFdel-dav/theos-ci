#pragma once
#import <UIKit/UIKit.h>
#import "LCSCellularService.h"
#import "LCSCellularCardLayout.h"
#if LCS_CELLULAR_DATA_MODULE
#define LCSCellularPanelController LCSDataModulePanelController
#define LCSCellularSIMController LCSDataModuleSIMController
#define LCSCellularDataController LCSDataModuleDataController
#define LCSCellularStatusRow LCSDataModuleStatusRow
#endif
@interface LCSCellularPanelController : UIViewController
+ (CGFloat)preferredCardHeight;
@property(nonatomic,copy) BOOL (^mayContinue)(void);
@property(nonatomic,copy) void (^didClose)(void);
- (instancetype)initWithKind:(LCSCellularKind)kind;
- (void)close;
- (void)activate;
- (void)deactivate;
@end
@interface LCSCellularSIMController : LCSCellularPanelController
@end
@interface LCSCellularDataController : LCSCellularPanelController
@end

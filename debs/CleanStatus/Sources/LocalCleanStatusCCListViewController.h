#pragma once
#import <UIKit/UIKit.h>
#import "LocalCleanStatusCCBackend.h"
@interface LCSCCListViewController : UIViewController
@property(nonatomic,copy) dispatch_block_t didClose;
@property(nonatomic,copy) BOOL (^mayContinue)(void);
- (instancetype)initWithKind:(LCSCCTargetKind)kind;
- (void)close;
@end

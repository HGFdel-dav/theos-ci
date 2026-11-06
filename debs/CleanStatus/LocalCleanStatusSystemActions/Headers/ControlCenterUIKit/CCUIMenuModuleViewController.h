#pragma once
#import "CCUIButtonModuleViewController.h"

// iOS 15 menu-style module controller. Only the members this bundle drives.
@interface CCUIMenuModuleViewController : CCUIButtonModuleViewController
@property(nonatomic, readonly) NSUInteger actionsCount;
- (void)addActionWithTitle:(NSString *)title glyph:(UIImage *)glyph handler:(void (^)(void))handler;
- (void)removeAllActions;
@end

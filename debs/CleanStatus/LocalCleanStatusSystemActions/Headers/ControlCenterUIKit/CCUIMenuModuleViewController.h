#pragma once
#import "CCUIButtonModuleViewController.h"

// CCUIMenuModuleViewController is not in the vendor headers; declare only the
// members this bundle drives.
@interface CCUIMenuModuleViewController : CCUIButtonModuleViewController
@property(nonatomic, readonly) NSUInteger actionsCount;
- (void)addActionWithTitle:(NSString *)title glyph:(UIImage *)glyph handler:(void (^)(void))handler;
- (void)removeAllActions;
@end

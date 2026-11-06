#pragma once
#import "CCUIButtonModuleViewController.h"

// CCUIMenuModuleViewController is not in the vendor headers; declare only the
// members this bundle drives. The subtitle variant and useTallLayout are chosen
// at runtime with respondsToSelector:, so a missing one cannot throw.
@interface CCUIMenuModuleViewController : CCUIButtonModuleViewController
@property(nonatomic, readonly) NSUInteger actionsCount;
@property(nonatomic) BOOL useTallLayout;
- (void)addActionWithTitle:(NSString *)title glyph:(UIImage *)glyph handler:(void (^)(void))handler;
- (void)addActionWithTitle:(NSString *)title subtitle:(NSString *)subtitle glyph:(UIImage *)glyph handler:(void (^)(void))handler;
- (void)removeAllActions;
@end

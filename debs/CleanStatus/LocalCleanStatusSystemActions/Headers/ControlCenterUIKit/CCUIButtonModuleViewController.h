#pragma once
#import <UIKit/UIKit.h>

// Minimal iOS 15 declarations, reduced to the members this bundle uses.
// Everything else stays inherited so the native platter/expansion logic runs.

@protocol CCUIContentModuleContentViewController <NSObject>
@property(nonatomic, readonly) CGFloat preferredExpandedContentWidth;
@property(nonatomic, readonly) CGFloat preferredExpandedContentHeight;
- (BOOL)shouldBeginTransitionToExpandedContentModule;
- (void)willTransitionToExpandedContentMode:(BOOL)expanded;
@end

@interface CCUIButtonModuleViewController : UIViewController <CCUIContentModuleContentViewController>
@property(nonatomic, strong) UIColor *selectedBackgroundColor;
@property(nonatomic, strong) UIImage *glyphImage;
- (void)buttonTapped:(id)sender forEvent:(id)event;
@end

@interface CCUIMenuModuleViewController : CCUIButtonModuleViewController
@property(nonatomic, readonly) NSUInteger actionsCount;
- (void)addActionWithTitle:(NSString *)title glyph:(UIImage *)glyph handler:(void (^)(void))handler;
- (void)removeAllActions;
@end

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
/// Content is measured only when text/width/expansion changes, NEVER when moving.
@interface MiniSightBubbleView : UIView
@property (nonatomic, copy, nullable) void (^onDecision)(BOOL allow);
@property (nonatomic, copy, nullable) void (^onSizeChanged)(void);
@property (nonatomic, readonly) BOOL approvalVisible;
- (void)showText:(NSString *)text approval:(BOOL)approval
       maxWidth:(CGFloat)width maxHeight:(CGFloat)height;
- (void)setTailX:(CGFloat)x;
- (void)invalidateApproval;
@end
NS_ASSUME_NONNULL_END

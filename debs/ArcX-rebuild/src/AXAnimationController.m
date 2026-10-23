#import "../headers/AXAnimationController.h"

@implementation AXAnimationController

- (void)playMenuAppearAnimation:(UIView *)menuView fromCorner:(NSInteger)corner {
    // TODO: 扇形展开动画（仿 ScreenCore 原版）
    menuView.alpha = 0;
    menuView.transform = CGAffineTransformMakeScale(0.3, 0.3);
    
    [UIView animateWithDuration:0.34 
                          delay:0 
         usingSpringWithDamping:0.75 
          initialSpringVelocity:0.8 
                        options:UIViewAnimationOptionAllowUserInteraction 
                     animations:^{
        menuView.alpha = 1.0;
        menuView.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)playItemSelectAnimation:(UIView *)itemView completion:(void(^)(void))completion {
    [UIView animateWithDuration:0.16 animations:^{
        itemView.transform = CGAffineTransformMakeScale(1.15, 1.15);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.12 animations:^{
            itemView.transform = CGAffineTransformIdentity;
        } completion:^(BOOL finished) {
            if (completion) completion();
        }];
    }];
}

@end

#import "../headers/SCFloatingContainerView.h"

@implementation SCFloatingContainerView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.95];
        self.layer.cornerRadius = 16;
        self.clipsToBounds = YES;
    }
    return self;
}

- (void)displayTarget:(SCApplicationTarget *)target {
    // TODO: 加载应用窗口内容
    NSLog(@"[SC] displayTarget %@", target);
}

- (void)updateContainerFrame:(CGRect)frame animated:(BOOL)animated {
    if (animated) {
        [UIView animateWithDuration:0.3 animations:^{
            self.frame = frame;
        }];
    } else {
        self.frame = frame;
    }
}

- (void)switchToFullscreen:(BOOL)fullscreen {
    // TODO: 全屏/浮窗切换
    NSLog(@"[SC] switchToFullscreen=%d", fullscreen);
}

@end

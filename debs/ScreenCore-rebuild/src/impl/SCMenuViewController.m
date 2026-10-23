#import "../headers/SCMenuViewController.h"

@implementation SCMenuViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // TODO: 构建菜单 UI
    self.view.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.92];
}

- (void)displayMenuForApplications:(NSArray<SCApplicationTarget *> *)targets {
    // TODO: 扇形/矩形布局菜单项
    NSLog(@"[SC] displayMenu %lu items", (unsigned long)targets.count);
}

- (void)selectTarget:(SCApplicationTarget *)target {
    // TODO: 通知协调器启动应用
    NSLog(@"[SC] selectTarget %@", target);
}

- (void)dismissAnimated:(BOOL)animated {
    [UIView animateWithDuration:animated ? 0.25 : 0 animations:^{
        self.view.alpha = 0;
    } completion:^(BOOL finished) {
        [self.view removeFromSuperview];
    }];
}

@end

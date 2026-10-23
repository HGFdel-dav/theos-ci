#import <UIKit/UIKit.h>

@interface PXHostViewController : UIViewController
@property (nonatomic, strong) UIView *hostView;
@property (nonatomic, strong) UIView *keyboardOverlay;
@property (nonatomic, copy) NSString *hostedBundleID;

- (void)hostApplication:(NSString *)bundleID;
- (void)resizeHostView:(CGRect)frame;
- (void)dismissHost;
@end

@implementation PXHostViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.hostView = [[UIView alloc] initWithFrame:CGRectMake(50, 100, 300, 500)];
    self.hostView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    self.hostView.layer.cornerRadius = 12;
    self.hostView.clipsToBounds = YES;
    [self.view addSubview:self.hostView];
    
    self.keyboardOverlay = [[UIView alloc] initWithFrame:self.view.bounds];
    self.keyboardOverlay.backgroundColor = [UIColor clearColor];
    self.keyboardOverlay.userInteractionEnabled = NO;
    [self.view addSubview:self.keyboardOverlay];
}

- (void)hostApplication:(NSString *)bundleID {
    self.hostedBundleID = bundleID;
    NSLog(@"[PX] hostApplication %@ in view %@", bundleID, self.hostView);
    // TODO: 注入应用 scene 到 hostView
}

- (void)resizeHostView:(CGRect)frame {
    [UIView animateWithDuration:0.25 animations:^{
        self.hostView.frame = frame;
    }];
}

- (void)dismissHost {
    [UIView animateWithDuration:0.2 animations:^{
        self.hostView.alpha = 0;
    } completion:^(BOOL finished) {
        [self.hostView removeFromSuperview];
        self.hostedBundleID = nil;
    }];
}

@end

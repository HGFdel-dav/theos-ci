#import <UIKit/UIKit.h>
#import "../Cellular/LCSCellularPanel.h"
#import "../Cellular/LCSCellularSettings.h"
#import "../Cellular/LCSCellularRuntime.h"

@protocol CCUIContentModuleContentViewController <NSObject>
@end
@protocol CCUIContentModule <NSObject>
- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController;
- (UIViewController *)backgroundViewController;
@end
@interface LCSDataSwitchContent : UIViewController <CCUIContentModuleContentViewController>
@property(nonatomic,strong) id moduleContext;
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) LCSCellularDataController *panel;
@property(nonatomic) BOOL expanded;
@end
@implementation LCSDataSwitchContent
- (void)loadView {
    self.view=[[UIView alloc] initWithFrame:CGRectMake(0,0,64,64)];self.view.backgroundColor=UIColor.clearColor;
    self.button=[UIButton buttonWithType:UIButtonTypeCustom];self.button.tintColor=UIColor.whiteColor;
    NSBundle *bundle=[NSBundle bundleForClass:self.class];
    UIImage *image=[UIImage imageNamed:@"DataSwitch" inBundle:bundle compatibleWithTraitCollection:nil];
    if(!image)image=[UIImage systemImageNamed:@"simcard.2"];
    [self.button setImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    self.button.imageView.contentMode=UIViewContentModeCenter;self.button.accessibilityLabel=@"数据切换";self.button.accessibilityHint=@"轻点选择默认上网 SIM";
    [self.button addTarget:self action:@selector(openPanel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.button];
    self.panel=[LCSCellularDataController new];
    __weak typeof(self) weakSelf=self;
    self.panel.mayContinue=^BOOL{typeof(self) s=weakSelf;return s&&s.expanded&&s.isViewLoaded&&s.view.window!=nil;};
    self.panel.didClose=^{[weakSelf dismissExpanded];};
    [self addChildViewController:self.panel];[self.view addSubview:self.panel.view];[self.panel didMoveToParentViewController:self];
    self.panel.view.hidden=YES;
}
- (double)preferredExpandedContentHeight {return [LCSCellularPanelController preferredCardHeight];}
- (double)preferredExpandedContentWidth {return LCS_CELLULAR_CARD_WIDTH;}
- (bool)providesOwnPlatter {return false;}
- (bool)shouldBeginTransitionToExpandedContentModule {
    return LCSCellularMayMutate(LCSCellularDataSwitch)&&!self.expanded;
}
- (bool)shouldFinishTransitionToExpandedContentModule {return true;}
- (bool)canDismissPresentedContent {return true;}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];self.button.frame=self.view.bounds;self.panel.view.frame=self.view.bounds;
}
- (void)openPanel {
    if(self.expanded)return;
    if(!LCSCellularMayMutate(LCSCellularDataSwitch)) {
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"请先在 CleanStatus 设置启用数据切换，并解锁设备。");return;
    }
    SEL sel=sel_registerName("requestExpandModule");
    if(LCSCellularMethod(object_getClass(self.moduleContext),sel,"v",0,NULL))((void(*)(id,SEL))objc_msgSend)(self.moduleContext,sel);
}
- (void)dismissExpanded {
    self.expanded=NO;[self.panel deactivate];self.panel.view.hidden=YES;self.button.hidden=NO;
    SEL sel=sel_registerName("dismissModule");
    if(LCSCellularMethod(object_getClass(self.moduleContext),sel,"v",0,NULL))((void(*)(id,SEL))objc_msgSend)(self.moduleContext,sel);
}
- (void)willTransitionToExpandedContentMode:(bool)expanded {
    self.expanded=expanded;self.button.hidden=expanded;self.panel.view.hidden=!expanded;
    if(!expanded)[self.panel deactivate];
}
- (void)didTransitionToExpandedContentMode:(bool)expanded {
    self.expanded=expanded;self.button.hidden=expanded;self.panel.view.hidden=!expanded;
    if(expanded)[self.panel activate];else [self.panel deactivate];
}
- (void)controlCenterDidDismiss {
    self.expanded=NO;[self.panel deactivate];self.panel.view.hidden=YES;self.button.hidden=NO;
}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];[self controlCenterDidDismiss];}
@end
@interface LCSDataSwitchModule : NSObject <CCUIContentModule>
@property(nonatomic,strong) LCSDataSwitchContent *controller;
@property(nonatomic,strong) id contentModuleContext;
@end
@implementation LCSDataSwitchModule
- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController {
    if(!self.controller){self.controller=[LCSDataSwitchContent new];self.controller.moduleContext=self.contentModuleContext;}
    return self.controller;
}
- (void)setContentModuleContext:(id)context {_contentModuleContext=context;self.controller.moduleContext=context;}
- (UIViewController *)backgroundViewController {return nil;}
@end

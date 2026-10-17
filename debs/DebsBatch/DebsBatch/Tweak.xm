//  DebsBatch — 注入入口
//  在 Debs「管理文件」页显示贴底按钮「上传我的源」，
//  点击弹出批量上传面板（DBUploadPanel）。
#import <UIKit/UIKit.h>
#import "DBCommon.h"
#import "DBUploadPanel.h"

static UIButton *gBatchButton = NULL;
static BOOL gBatchButtonVisible = NO;

#pragma mark - 页面识别（管理文件）

static BOOL DBIsManageFilesPage(void) {
    UIViewController *top = DBTopViewController();
    if (!top) return NO;
    NSString *title = top.title;
    if (!title.length) title = top.navigationItem.title;
    if (title.length &&
        ([title rangeOfString:@"管理文件"].location != NSNotFound ||
         [title rangeOfString:@"Downloads"].location != NSNotFound)) {
        return YES;
    }
    // 兜底：SwiftUI 标题常藏在导航栏子视图中（BFS 查找 UILabel）
    UINavigationBar *bar = top.navigationController.navigationBar;
    if (bar) {
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:bar];
        for (NSInteger i = 0; i < (NSInteger)queue.count && i < 80; i++) {
            UIView *v = queue[(NSUInteger)i];
            if ([v isKindOfClass:[UILabel class]]) {
                NSString *t = ((UILabel *)v).text;
                if (t.length && [t rangeOfString:@"管理文件"].location != NSNotFound) return YES;
            }
            [queue addObjectsFromArray:v.subviews];
        }
    }
    return NO;
}

#pragma mark - 悬浮按钮同步

static void DBSyncBatchButton(void) {
    UIWindow *win = DBKeyWindow();
    if (!win) return;
    BOOL shouldShow = DBIsManageFilesPage();
    if (shouldShow == gBatchButtonVisible) return;
    gBatchButtonVisible = shouldShow;

    if (!gBatchButton) {
        gBatchButton = [UIButton buttonWithType:UIButtonTypeSystem];
        gBatchButton.backgroundColor = [UIColor systemBlueColor];
        gBatchButton.layer.cornerRadius = 12.0;
        [gBatchButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [gBatchButton.titleLabel setFont:[UIFont boldSystemFontOfSize:15.0]];
        [gBatchButton setTitle:@"上传我的源" forState:UIControlStateNormal];
        [gBatchButton addTarget:[DBUploadPanelViewController class]
                         action:@selector(presentBatch)
               forControlEvents:UIControlEventTouchUpInside];
    }

    if (shouldShow) {
        if (!gBatchButton.superview) [win addSubview:gBatchButton];
        CGFloat w = CGRectGetWidth(win.bounds);
        CGFloat h = 46.0;
        CGFloat bottomInset = win.safeAreaInsets.bottom;
        // 贴底：TabBar 上方（TabBar 约 49pt + 安全区）
        CGFloat y = CGRectGetHeight(win.bounds) - bottomInset - 49.0 - 12.0 - h;
        gBatchButton.frame = CGRectMake(16.0, y, w - 32.0, h);
        gBatchButton.hidden = NO;
        [win bringSubviewToFront:gBatchButton];
    } else {
        gBatchButton.hidden = YES;
    }
}

#pragma mark - 面板入口（隐藏按钮再弹出）

@interface DBUploadPanelViewController (DebsBatchEntry)
+ (void)presentBatch;
@end

@implementation DBUploadPanelViewController (DebsBatchEntry)

+ (void)presentBatch {
    // 先隐藏悬浮按钮，避免盖在面板上
    gBatchButton.hidden = YES;
    gBatchButtonVisible = NO;
    UIViewController *top = DBTopViewController();
    if (top) {
        [self presentFromViewController:top];
    }
}

@end

#pragma mark - 钩子：Tab 切换后立即同步

%hook UITabBarController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DBSyncBatchButton();
    });
}

%end

#pragma mark - 构造：常驻定时器兜底（页面 push/pop 也能感知）

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DBSyncBatchButton();
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.8
                                                repeats:YES
                                                  block:^(NSTimer *t) {
            DBSyncBatchButton();
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    });
}
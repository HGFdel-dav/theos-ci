//
//  DNBNewsBarView.h
//  DebsNewsBatch
//
//  新闻页底部条：平时是「新闻批量下载 · 选择软件包」，点一下进选择态；
//  选择态变成「取消 / 已选 N / 全选 / 下载」；下载中显示进度；完成后显示统计。
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, DNBNewsBarState) {
    DNBNewsBarStateIdle = 0,
    DNBNewsBarStateSelecting,
    DNBNewsBarStateRunning,
    DNBNewsBarStateDone
};

@class DNBNewsBarView;

@protocol DNBNewsBarDelegate <NSObject>
- (void)barDidTapBody:(DNBNewsBarView *)bar;
- (void)barDidTapCancel:(DNBNewsBarView *)bar;
- (void)barDidTapSelectAll:(DNBNewsBarView *)bar;
- (void)barDidTapDownload:(DNBNewsBarView *)bar;
- (void)barDidTapStop:(DNBNewsBarView *)bar;
- (void)barDidTapDone:(DNBNewsBarView *)bar;
- (void)barDidLongPress:(DNBNewsBarView *)bar;
@end

@interface DNBNewsBarView : UIView

@property (nonatomic, weak) id<DNBNewsBarDelegate> delegate;
@property (nonatomic, assign) DNBNewsBarState state;
@property (nonatomic, assign) NSInteger selectedCount;
@property (nonatomic, assign) BOOL allSelected;

@property (nonatomic, readonly) UILabel *titleLabel;

- (void)showProgressDone:(NSInteger)done
                   total:(NSInteger)total
                 success:(NSInteger)success
                  failed:(NSInteger)failed;
- (void)showSummarySuccess:(NSInteger)success
                    failed:(NSInteger)failed
                   skipped:(NSInteger)skipped;
- (void)applyTintColor:(UIColor *)tint;

@end

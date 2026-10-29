//
//  MHHandle.h
//  MessageHub
//
//  Created by Will Smillie on 1/18/19.
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSUInteger, POHandleLayoutMode) {
    POHandleLayoutModeVerticalRail,
    POHandleLayoutModeLandscapeFixedBottomLeft,
};

@class POHandle;
@protocol POHandleDelegate <NSObject>
- (void)handle:(POHandle *)handle didReceiveTap:(UIGestureRecognizer*)recognizer;
- (void)handle:(POHandle *)handle didLongPress:(UIGestureRecognizer*)recognizer;
- (void)handle:(POHandle *)handle didPanPanel:(UIPanGestureRecognizer *)recognizer;
@end


@interface POHandle : UIView

@property (nonatomic, weak) id <POHandleDelegate> delegate;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic) BOOL isNubbed;
@property (nonatomic) CGFloat restingOriginX;
@property (nonatomic) POHandleLayoutMode layoutMode;

-(instancetype)initWithController:(id)controller;
-(void)refreshHandleSizeAnimated:(BOOL)animated;
-(void)refreshNubbedPositionAnimated:(BOOL)animated;
-(void)restoreRestingAppearance;
/// 分屏窗口打开时隐藏视觉层，但保留触摸区域。
-(void)setHostedWindowOpen:(BOOL)open;


@end

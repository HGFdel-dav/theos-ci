//
//  DNBRowTarget.h
//  DebsNewsBatch
//
//  盖在一条新闻行上的透明选择控件：左侧画勾选圈，右侧可显示下载状态。
//  它盖在行上面，所以选择态下点行不会触发 App 自己的跳转。
//

#import <UIKit/UIKit.h>

@interface DNBRowTarget : UIControl

@property (nonatomic, copy) NSString *rowKey;
@property (nonatomic, assign, getter=isChosen) BOOL chosen;
@property (nonatomic, copy) NSString *statusText;

@end

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSControlTableCell.h>

/// 标题 + 数值 + 滑杆，数值可点开直接输入。PX 那种调参行。
@interface POSliderTableCell : PSControlTableCell
@property (nonatomic, strong) UILabel *valueLabel;
@end

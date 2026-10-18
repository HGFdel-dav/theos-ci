// TWCells.h — Twin's custom preference cells (self-drawn, own look).
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSListController.h>
#import "TWStyle.h"
#import "TWPrefs.h"

NS_ASSUME_NONNULL_BEGIN

// Shared scaffolding: tinted symbol chip + bold title + right-aligned control.
@interface TWBaseCell : PSTableCell
- (void)twBuild;                                                  // one-time subview setup
- (void)twApplyAppearance;                                        // chip/title/dimming
- (void)twSaveObject:(nullable id)value forKey:(nullable NSString *)key;
- (void)twNotifyHostReload;
- (CGFloat)twLayoutControlInHeight:(CGFloat)height width:(CGFloat)width; // returns control width
// 0.4.0：逐行取色。specifier 的 twColor（调色板下标）优先，否则按标题稳定取色。
- (nullable UIColor *)twRowColor;
- (void)twApplyRowColor:(nullable UIColor *)color;                // 子类把控件染成该行颜色
- (BOOL)twUsesWideLayout;                                         // twWideSegment：标题在上、控件整行在下
@end

@interface TWSwitchCell : TWBaseCell @end          // BOOL value；带 twBit 时读写位掩码的某一位
@interface TWSliderCell : TWBaseCell @end          // float/int value, two-line layout
@interface TWSegmentCell : TWBaseCell @end         // integer index, 2+ segments
@interface TWActionCell : TWBaseCell @end          // link row (chevron) or destructive action
@interface TWStatusCell : TWBaseCell @end          // read-only status readout

NS_ASSUME_NONNULL_END
// TWStyle.h — Twin's own visual language.
// The panel deliberately does NOT look like a stock specifier list: it uses a
// gradient hero header with the Twin mark, tinted icon chips per row, a violet
// accent for every control and a monospaced value readout.
//
// 0.4.0: chips are no longer monochrome. Every row picks its own colour from a
// 10-hue palette (explicit twColor index, otherwise a stable hash of the row
// title, so the panel is never "all purple" and colours stay put across launches).
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Rounded tinted square holding an SF Symbol (falls back to the row initial).
@interface TWChipView : UIView
@property (nonatomic, strong, readonly) UIImageView *glyphView;
@property (nonatomic, strong, readonly) UILabel *fallbackLabel;
@property (nonatomic, strong, readonly, nullable) UIColor *chipColor;
- (void)setSymbolNamed:(nullable NSString *)name fallbackText:(nullable NSString *)text;
// 逐行取色：背景用同色 14% 透明度，图标/首字母用本色。
- (void)setChipColor:(nullable UIColor *)color;
@end

@interface TWStyle : NSObject

+ (UIColor *)accent;       // Twin violet (hero / 强调)
+ (UIColor *)accentAlt;    // Twin cyan
+ (UIColor *)accentSoft;   // accent at 15% (chip background)
+ (UIColor *)danger;       // destructive red
+ (NSArray<UIColor *> *)gradientColors;

// 10 色调色板（无紫色，避免整页一种颜色）。
+ (NSArray<UIColor *> *)palette;
+ (UIColor *)paletteColorAtIndex:(NSInteger)index;
// 稳定取色：同一个标题在每次启动都得到同一个颜色（不用 NSString.hash——
// 它是按进程加盐的，会导致每次启动换色）。
+ (UIColor *)chipColorForIdentifier:(nullable NSString *)identifier;

+ (UIFont *)rowTitleFont;
+ (UIFont *)rowValueFont;
+ (UIFont *)heroTitleFont;
+ (UIFont *)heroSubtitleFont;

+ (TWChipView *)chipWithSymbol:(nullable NSString *)symbol fallback:(nullable NSString *)text;
+ (UIView *)heroHeaderWithTitle:(NSString *)title
                       subtitle:(NSString *)subtitle
                     statusText:(NSString *)statusText
                        enabled:(BOOL)enabled
                          width:(CGFloat)width;

@end

NS_ASSUME_NONNULL_END
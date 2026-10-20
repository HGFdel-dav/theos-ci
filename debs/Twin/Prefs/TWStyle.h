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

// ── 0.9.25：全页面统一网格 ────────────────────────────────────────────
// 以前滑杆行标题写在 x=16、开关/分段行写在 x=64、图标列表页又是另一套，
// 翻页时文字左边距一直在跳，看着"没对齐"。现在全面板只有这一条网格：
//   图标列：x=16，44×44（圆形色块/应用图标都在这一列）
//   文字列：x=64（所有行、所有页一律 64）
//   右侧控件：距右 16
#define TWGridIconX     16.0
#define TWGridIconSize  44.0
#define TWGridTextX     64.0
#define TWGridRight     16.0

// 按统一网格排版的行（应用图标列表、多选页等自绘页都用它）。
@interface TWIconCell : UITableViewCell
@end

// 0.9.0：10 色图标色板（按 twColor 索引取色，行图标背景用本色、符号用白色）。
// 定义在 TWSpecifiers.m，TWIconCells.m 也用它渲染图标图。
FOUNDATION_EXPORT UIColor *TWIconTintColor(NSInteger idx);

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
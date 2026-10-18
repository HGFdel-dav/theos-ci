// TWStyle.h — Twin's own visual language.
// The panel deliberately does NOT look like a stock specifier list: it uses a
// gradient hero header with the Twin mark, tinted icon chips per row, a violet
// accent for every control and a monospaced value readout.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Rounded tinted square holding an SF Symbol (falls back to the row initial).
@interface TWChipView : UIView
@property (nonatomic, strong, readonly) UIImageView *glyphView;
@property (nonatomic, strong, readonly) UILabel *fallbackLabel;
- (void)setSymbolNamed:(nullable NSString *)name fallbackText:(nullable NSString *)text;
@end

@interface TWStyle : NSObject

+ (UIColor *)accent;       // Twin violet
+ (UIColor *)accentAlt;    // Twin cyan
+ (UIColor *)accentSoft;   // accent at 15% (chip background)
+ (UIColor *)danger;       // destructive red
+ (NSArray<UIColor *> *)gradientColors;

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
// TWArcGeometry.h
// 角落版几何（0.4.0）：手势从屏幕**角落**起手，图标以该角为圆心扇形展开。
// 旧版是"沿选定边缘的竖条触发"，与 ParallelX 手柄重复，已按用户要求改掉。
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TWCorner) {
    TWCornerBottomRight = 0,   // 右下
    TWCornerBottomLeft  = 1,   // 左下
    TWCornerTopLeft     = 2,   // 左上
    TWCornerTopRight    = 3,   // 右上
};

@interface TWArcGeometry : NSObject
// 命中哪个角落（cornersMask 位掩码 = 1<<TWCorner*），未命中返回 -1。
// bounds 为屏幕尺寸；statusZone 为顶部状态栏/底部 Home 条保留高度。
+ (NSInteger)cornerAtPoint:(CGPoint)point corners:(NSInteger)cornersMask size:(CGFloat)size bounds:(CGRect)bounds;

// 扇形总角度（弧度）：一个象限。
+ (CGFloat)sweepAngle;

// 角落对应的起始角（UIKit 坐标：0=向右，π/2=向下）。
+ (CGFloat)startAngleForCorner:(NSInteger)corner;

// 弧心位置：从角落往屏内缩 margin，保证贴边的图标不出屏。
+ (CGPoint)anchorForCorner:(NSInteger)corner margin:(CGFloat)margin bounds:(CGRect)bounds;

// 半径上限：把整个扇形塞进屏幕（不越出对角线外侧两条边）。
+ (CGFloat)maxRadiusForCorner:(NSInteger)corner anchor:(CGPoint)anchor margin:(CGFloat)margin bounds:(CGRect)bounds;

// 半径适配：既要排得下 count 个图标，又不让扇形出屏。
+ (CGFloat)radiusForItemCount:(NSInteger)count preferredRadius:(CGFloat)radius menuScale:(CGFloat)scale corner:(NSInteger)corner bounds:(CGRect)bounds;

// 图标直径：按相邻圆心弦长反推。
+ (CGFloat)itemSizeForCount:(NSInteger)count radius:(CGFloat)radius menuScale:(CGFloat)scale;

// 第 index 个（0-based）图标中心。
+ (CGPoint)centerForItemAtIndex:(NSInteger)index count:(NSInteger)count radius:(CGFloat)radius anchor:(CGPoint)anchor corner:(NSInteger)corner bounds:(CGRect)bounds;

#pragma mark - 多环扇形（ScreenCore 几何）

// 屏幕角落的扇形排布：90° 象限内按环排开，第一环 firstRowCount 个，
// 后续环按半径加大继续排，直到 n 个图标全部放下。
// 返回 NSArray<NSValue *>（CGPoint），顺序与条目顺序一致。
// 几何来自 ScreenCore 2.0.4（起始角 180°、扫描角 90°），排布用等效实现。
+ (NSArray<NSValue *> *)centersForCount:(NSInteger)count
                          firstRowCount:(NSInteger)firstRowCount
                               iconSize:(CGFloat)iconSize
                                  radius:(CGFloat)radius
                                ringGap:(CGFloat)ringGap
                                 anchor:(CGPoint)anchor
                                 corner:(NSInteger)corner
                                 bounds:(CGRect)bounds;

// 在给定几何下算出实际使用的半径上限（不越出屏幕）。
+ (CGFloat)clampedRadius:(CGFloat)radius anchor:(CGPoint)anchor corner:(NSInteger)corner bounds:(CGRect)bounds;
@end

NS_ASSUME_NONNULL_END
#import <UIKit/UIKit.h>
#import "../headers/SCApplicationTarget.h"

typedef NS_ENUM(NSInteger, SCMenuLayoutMode) {
    SCMenuLayoutModeFan = 0,      // 扇形
    SCMenuLayoutModeRectangle = 1  // 矩形
};

@interface SCMenuLayoutEngine : NSObject
@property (nonatomic, assign) SCMenuLayoutMode mode;
@property (nonatomic, assign) CGFloat iconSize;      // 图标大小
@property (nonatomic, assign) CGFloat arcRadius;    // 扇形半径
@property (nonatomic, assign) CGFloat arcAngle;     // 扇形角度
@property (nonatomic, assign) CGSize rectangleSize; // 矩形尺寸
@property (nonatomic, assign) CGFloat cornerRadius; // 矩形圆角

- (NSArray<NSValue *> *)layoutPositionsForItemCount:(NSInteger)count
                                          fromCorner:(NSInteger)corner
                                        screenBounds:(CGRect)bounds;
- (CGRect)menuContainerFrameForCorner:(NSInteger)corner
                         screenBounds:(CGRect)bounds
                            itemCount:(NSInteger)count;
@end

@implementation SCMenuLayoutEngine

- (instancetype)init {
    if (self = [super init]) {
        _mode = SCMenuLayoutModeFan;
        _iconSize = 44;
        _arcRadius = 120;
        _arcAngle = 60; // 度
        _rectangleSize = CGSizeMake(200, 300);
        _cornerRadius = 16;
    }
    return self;
}

- (NSArray<NSValue *> *)layoutPositionsForItemCount:(NSInteger)count
                                          fromCorner:(NSInteger)corner
                                        screenBounds:(CGRect)bounds {
    if (_mode == SCMenuLayoutModeFan) {
        return [self fanLayoutForCount:count corner:corner];
    } else {
        return [self rectangleLayoutForCount:count corner:corner];
    }
}

- (NSArray<NSValue *> *)fanLayoutForCount:(NSInteger)count corner:(NSInteger)corner {
    NSMutableArray *positions = [NSMutableArray array];
    
    CGFloat angleStep = _arcAngle / MAX(1, count - 1);
    CGFloat startAngle = -_arcAngle / 2;
    
    // 根据角落调整基准角度
    CGFloat baseAngle = 0;
    switch (corner) {
        case 0: baseAngle = 45; break;  // 左下
        case 1: baseAngle = 135; break; // 右下
        case 2: baseAngle = -45; break; // 左上
        case 3: baseAngle = -135; break;// 右上
    }
    
    for (NSInteger i = 0; i < count; i++) {
        CGFloat angle = (baseAngle + startAngle + i * angleStep) * M_PI / 180.0;
        CGFloat x = _arcRadius * cos(angle);
        CGFloat y = _arcRadius * sin(angle);
        [positions addObject:[NSValue valueWithCGPoint:CGPointMake(x, y)]];
    }
    
    return positions;
}

- (NSArray<NSValue *> *)rectangleLayoutForCount:(NSInteger)count corner:(NSInteger)corner {
    NSMutableArray *positions = [NSMutableArray array];
    
    NSInteger cols = 2;
    NSInteger rows = (count + cols - 1) / cols;
    CGFloat spacing = 12;
    
    for (NSInteger i = 0; i < count; i++) {
        NSInteger row = i / cols;
        NSInteger col = i % cols;
        CGFloat x = col * (_iconSize + spacing) + spacing;
        CGFloat y = row * (_iconSize + spacing) + spacing;
        [positions addObject:[NSValue valueWithCGPoint:CGPointMake(x, y)]];
    }
    
    return positions;
}

- (CGRect)menuContainerFrameForCorner:(NSInteger)corner
                         screenBounds:(CGRect)bounds
                            itemCount:(NSInteger)count {
    if (_mode == SCMenuLayoutModeFan) {
        CGFloat size = _arcRadius * 2 + _iconSize;
        CGFloat x = (corner == 0 || corner == 2) ? 0 : bounds.size.width - size;
        CGFloat y = (corner == 0 || corner == 1) ? bounds.size.height - size : 0;
        return CGRectMake(x, y, size, size);
    } else {
        CGFloat x = (corner == 0 || corner == 2) ? 0 : bounds.size.width - _rectangleSize.width;
        CGFloat y = (corner == 0 || corner == 1) ? bounds.size.height - _rectangleSize.height : 0;
        return CGRectMake(x, y, _rectangleSize.width, _rectangleSize.height);
    }
}

@end

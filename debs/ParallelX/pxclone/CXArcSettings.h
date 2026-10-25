// CXArcSettings.h — 与旧触发设置相同的枚举/范围，统一读写 CX 偏好域。
#pragma once
#import <Foundation/Foundation.h>

static inline NSDictionary<NSString *, NSNumber *> *CXArcDefaultValues(void) {
    return @{@"CXArcEnabled": @YES, @"CXArcSide": @2, @"CXArcTriggerRegionMode": @0,
             @"CXArcRadius": @40, @"CXArcRectangleLength": @40, @"CXArcRectangleHeight": @40,
             @"CXArcRectangleCornerRadius": @12, @"CXArcOffsetX": @0, @"CXArcOffsetY": @0,
             @"CXArcMenuRadius": @140, @"CXArcIconSize": @44, @"CXArcFirstRowItemCount": @5,
             @"CXArcIconSpacing": @10, @"CXArcMenuScalePercent": @100,
             @"CXArcLandscapeMenuScalePercent": @100, @"CXArcMenuEdgeInset": @0,
             @"CXArcPortraitOffsetDistance": @0, @"CXArcLandscapeOffsetDistance": @0,
             @"CXArcLandscapeHorizontalOffset": @0, @"CXArcMirror": @NO, @"CXArcDebug": @NO};
}

static inline id CXArcDefaultValue(NSString *key) {
    return CXArcDefaultValues()[key];
}

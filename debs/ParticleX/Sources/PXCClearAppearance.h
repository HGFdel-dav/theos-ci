#pragma once
#import <UIKit/UIKit.h>

@interface PXCClearGlassButton : UIButton
- (void)pxcApplyStyle:(NSUInteger)style glyphSize:(CGFloat)glyphSize;
@end
void PXCClearAppearancePlace(PXCClearGlassButton *button,UIView *host);
void PXCClearAppearanceInstallHooks(void);

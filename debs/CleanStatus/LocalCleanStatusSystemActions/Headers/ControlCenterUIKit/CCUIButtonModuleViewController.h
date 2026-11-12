#pragma once
#import <UIKit/UIKit.h>

// Minimal iOS 15 declarations, reduced to the members this bundle uses.
// Everything else stays inherited so the native platter/expansion logic runs.

#import <ControlCenterUIKit/CCUIContentModuleContentViewController-Protocol.h>


@interface CCUIButtonModuleViewController : UIViewController <CCUIContentModuleContentViewController>
@property(nonatomic, strong) UIColor *selectedBackgroundColor;
@property(nonatomic, strong) UIImage *glyphImage;
- (void)buttonTapped:(id)sender forEvent:(id)event;
@end

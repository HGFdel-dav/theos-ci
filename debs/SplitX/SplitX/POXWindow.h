//
//  POXWindow.h
//  SplitX
//
//  Created by Will Smillie on 4/8/19.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "SplitViewController.h"

@interface POXWindow : UIWindow

@property (nonatomic, strong) SplitViewController *controller;
@property (nonatomic, assign, readonly) UIInterfaceOrientation pullOverInterfaceOrientation;

+ (id)sharedWindow;
- (void)requestLayoutFromCurrentScene;
- (BOOL)applyInterfaceOrientation:(UIInterfaceOrientation)orientation
                         duration:(NSTimeInterval)duration
                       completion:(void (^)(void))completion;

@end

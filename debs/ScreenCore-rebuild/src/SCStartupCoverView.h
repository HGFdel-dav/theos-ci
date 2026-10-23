// SCStartupCoverView.h - 逆向重建自 ScreenCore 2.0.4
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface SCStartupCoverView : NSObject

- (id)sc_pollHostedContentReadinessForHostView:startupCoverView:generation:;
- (id)sc_revealHostedContentForHostView:startupCoverView:generation:;
- (id)sc_startupCoverViewForBundleIdentifier:size:;
- (id)setStartupCoverView:;

@end

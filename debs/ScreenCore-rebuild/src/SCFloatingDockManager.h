// SCFloatingDockManager.h - 逆向重建自 ScreenCore 2.0.4
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface SCFloatingDockManager : NSObject

- (id)sc_floatingDockManager:didChangeGeometryForSession:;
- (id)sc_floatingDockManager:didRequestCloseSession:;
- (id)sc_floatingDockManager:didRequestExpandSession:;
- (id)sc_floatingDockManager:willDismissSession:;
- (id)v32@0:8@"SCFloatingDockManager"16@"SCFloatingSceneSession"24;

@end

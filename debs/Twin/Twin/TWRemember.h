// TWRemember.h — remember per-app floating window size/position (ScreenCore-style)
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

FOUNDATION_EXPORT void TWRememberStart(void); // idempotent, safe; installs hooks when PXPanelEntry exists
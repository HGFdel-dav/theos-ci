// PXPRemember.h — remember per-app floating window size/position (ScreenCore-style)
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

FOUNDATION_EXPORT void PXPRememberStart(void); // idempotent, safe; installs hooks when PXPanelEntry exists
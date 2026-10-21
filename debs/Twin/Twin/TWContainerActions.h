#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void TWContainerActionsStart(void);
// Only true during the synchronous call following a verified container switch.
FOUNDATION_EXPORT BOOL TWContainerActionLaunchIsPrepared(NSString *bundleID);

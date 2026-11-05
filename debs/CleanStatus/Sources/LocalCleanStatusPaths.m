#import "LocalCleanStatusPaths.h"

// Use the same logical path from Preferences and SpringBoard. RootHide may
// redirect /var/mobile at the filesystem layer; don't second-guess that mapping.
static NSString * const local_cleanstatus_logicalPreferencePath =
    @"/var/mobile/Library/Preferences/com.local.cleanstatus.plist";

NSString *local_cleanstatus_preferencesPath(void) {
    return local_cleanstatus_logicalPreferencePath;
}

// The destination is a fixed logical path, not caller-controlled input.
// '/' is the containment boundary; migrations use canonical paths separately.
NSString *local_cleanstatus_selectedRoot(void) {
    return @"/";
}

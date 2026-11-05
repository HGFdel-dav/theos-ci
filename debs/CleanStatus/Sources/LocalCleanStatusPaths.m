#import "LocalCleanStatusPaths.h"
#import <roothide.h>

static NSString * const local_cleanstatus_preferenceSuffix = @"/var/mobile/Library/Preferences/com.local.cleanstatus.plist";

NSString *local_cleanstatus_selectedRoot(void) {
    static NSString *selected;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *resolved=jbroot(@"/var/mobile/Library/Preferences/com.local.cleanstatus.plist");
        if (![resolved hasSuffix:local_cleanstatus_preferenceSuffix]) return;
        NSString *root=[resolved substringToIndex:resolved.length-local_cleanstatus_preferenceSuffix.length];
        NSString *prefix=[local_cleanstatus_appGroupDirectory stringByAppendingString:@"/.jbroot-"];
        struct stat st;
        if ([root hasPrefix:prefix] && lstat(root.fileSystemRepresentation,&st)==0 && S_ISDIR(st.st_mode))
            selected=[root copy];
    });
    return selected;
}

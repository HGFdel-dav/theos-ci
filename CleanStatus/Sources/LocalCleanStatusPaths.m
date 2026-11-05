#import "LocalCleanStatusPaths.h"
#import <roothide.h>

static NSString * const local_cleanstatus_mobileSuffix = @"/var/mobile";

NSString *local_cleanstatus_selectedRoot(void) {
    static NSString *selected;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *mobileHome = jbroot(@"/var/mobile").stringByStandardizingPath;
        if (![mobileHome hasSuffix:local_cleanstatus_mobileSuffix] ||
            mobileHome.length <= local_cleanstatus_mobileSuffix.length) return;

        NSString *candidate = [mobileHome substringToIndex:mobileHome.length-local_cleanstatus_mobileSuffix.length];
        struct stat st;
        if (lstat(candidate.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) return;

        NSString *root = candidate.stringByResolvingSymlinksInPath.stringByStandardizingPath;
        NSString *base = local_cleanstatus_appGroupDirectory.stringByResolvingSymlinksInPath.stringByStandardizingPath;
        NSString *name = root.lastPathComponent;
        if (![name hasPrefix:@".jbroot-"] || name.length <= @".jbroot-".length ||
            ![root.stringByDeletingLastPathComponent isEqualToString:base]) return;
        selected = [root copy];
    });
    return selected;
}

#pragma once
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import <fcntl.h>
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#else
#import <rootless.h>
#endif

#define PXC_PREFS_DOMAIN @"com.niubiprass.particlex"
#define PXC_CHANGED_CF CFSTR("com.niubiprass.particlex/changed")
#define PXC_PREVIEW_CF CFSTR("com.niubiprass.particlex/preview")

// Use the active RootHide root from libroothide. Never guess a UUID or write
// a host /var/mobile preference. Both SpringBoard and the prefs bundle share it.
static inline NSString *PXCPrivateHome(void) {
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(@"/var/mobile");
#else
    return @"/var/mobile";
#endif
}
static inline NSString *PXCPreferencePath(void) {
    return [[PXCPrivateHome() stringByAppendingPathComponent:@"Library/Preferences"]
        stringByAppendingPathComponent:[PXC_PREFS_DOMAIN stringByAppendingString:@".plist"]];
}
static inline NSString *PXCLogPath(void) {
    return [[PXCPrivateHome() stringByAppendingPathComponent:@"Library/Logs/ParticleX"]
        stringByAppendingPathComponent:@"runtime.log"];
}
static inline NSDictionary *PXCReadPreferences(void) {
    NSString *path = PXCPreferencePath();
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode) ||
        st.st_nlink != 1 || st.st_size > 65536) return @{};
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    return [d isKindOfClass:NSDictionary.class] ? d : @{};
}

#pragma once
#import <Foundation/Foundation.h>
#import <sys/stat.h>

// Canonicalize BEFORE appending writable paths. Reject symlink escapes.
static inline BOOL local_cleanstatus_pathInsideRoot(NSString *path, NSString *root) {
    if (!path.length || !root.length) return NO;
    NSString *canonicalRoot = root.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    NSString *canonicalPath = path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    NSString *prefix = [canonicalRoot isEqualToString:@"/"] ? @"/" : [canonicalRoot stringByAppendingString:@"/"];
    return [canonicalPath isEqualToString:canonicalRoot] || [canonicalPath hasPrefix:prefix];
}

static NSString * const local_cleanstatus_preferenceDomain = @"com.local.cleanstatus";
static NSString * const local_cleanstatus_preferenceRelative = @"var/mobile/Library/Preferences/com.local.cleanstatus.plist";
static NSString * const local_cleanstatus_appGroupDirectory = @"/var/mobile/Containers/Shared/AppGroup";

// Current root is resolved once in LocalCleanStatusPaths.m through RootHide's jbroot API.
// Directory enumeration is reserved for the explicit legacy migration below.
FOUNDATION_EXPORT NSString *local_cleanstatus_preferencesPath(void);
FOUNDATION_EXPORT NSString *local_cleanstatus_selectedRoot(void);
static inline NSArray<NSString *> *local_cleanstatus_migrationRoots(void) {
    NSMutableArray *roots = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:local_cleanstatus_appGroupDirectory error:nil]) {
        if (![name hasPrefix:@".jbroot-"]) continue;
        NSString *root=[local_cleanstatus_appGroupDirectory stringByAppendingPathComponent:name];
        struct stat st;
        if (lstat(root.fileSystemRepresentation,&st)==0 && S_ISDIR(st.st_mode)) [roots addObject:root];
    }
    return roots;
}

static inline NSDictionary *local_cleanstatus_readDictionary(NSString *path) {
    if (!path.length) return nil;
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode) ||
        st.st_nlink != 1 || st.st_size > 65536 || st.st_size <= 0) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    id plist = data ? [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:NULL error:nil] : nil;
    return [plist isKindOfClass:NSDictionary.class] ? plist : nil;
}

static inline NSError *local_cleanstatus_error(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:local_cleanstatus_preferenceDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

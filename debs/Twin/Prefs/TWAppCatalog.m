#import "TWAppCatalog.h"
#import "TWPath.h"
#import <objc/message.h>
#import <string.h>

static NSString *TWACString(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }
static BOOL TWACVisible(NSDictionary *info) {
    NSArray *tags = [info[@"SBAppTags"] isKindOfClass:NSArray.class] ? info[@"SBAppTags"] : @[];
    return ![tags containsObject:@"hidden"] && ![info[@"SBInternalApp"] boolValue];
}
static void TWACBundle(NSString *path, NSMutableOrderedSet *ids) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *bundleID = TWACString(info[@"CFBundleIdentifier"]), *exe = TWACString(info[@"CFBundleExecutable"]);
    if (bundleID.length && exe.length && [info[@"CFBundlePackageType"] isEqual:@"APPL"] && TWACVisible(info) &&
        [NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:exe]]) [ids addObject:bundleID];
}

NSArray<NSString *> *TWInstalledAppIdentifiers(void) {
    NSMutableOrderedSet<NSString *> *ids = [NSMutableOrderedSet orderedSet];
    @try {
        Class cls = NSClassFromString(@"LSApplicationWorkspace");
        SEL shared = NSSelectorFromString(@"defaultWorkspace");
        id ws = [cls respondsToSelector:shared] ? ((id (*)(id, SEL))objc_msgSend)(cls, shared) : nil;
        // Original PXInstalledApplications (0x4341c) uses workspace enumeration,
        // applicationIdentifier and application visibility. Never exclude Apple apps by prefix.
        for (NSString *name in @[@"allInstalledApplications", @"allApplications"]) {
            SEL query = NSSelectorFromString(name);
            if (![ws respondsToSelector:query]) continue;
            id raw = ((id (*)(id, SEL))objc_msgSend)(ws, query);
            if (![raw isKindOfClass:NSArray.class]) continue;
            for (id proxy in raw) {
                @try {
                    SEL bidSel = NSSelectorFromString(@"applicationIdentifier");
                    NSString *bid = [proxy respondsToSelector:bidSel] ? TWACString(((id (*)(id, SEL))objc_msgSend)(proxy, bidSel)) : nil;
                    if (!bid.length) continue;
                    SEL restricted = NSSelectorFromString(@"isRestricted");
                    NSMethodSignature *sig = [proxy methodSignatureForSelector:restricted];
                    if (sig.numberOfArguments == 2 && (!strcmp(sig.methodReturnType, @encode(BOOL)) || !strcmp(sig.methodReturnType, "c"))) {
                        if (((BOOL (*)(id, SEL))objc_msgSend)(proxy, restricted)) continue;
                    }
                    SEL urlSel = NSSelectorFromString(@"bundleURL");
                    NSURL *url = [proxy respondsToSelector:urlSel] ? ((id (*)(id, SEL))objc_msgSend)(proxy, urlSel) : nil;
                    NSDictionary *info = [url isKindOfClass:NSURL.class] ? [NSDictionary dictionaryWithContentsOfFile:[url.path stringByAppendingPathComponent:@"Info.plist"]] : nil;
                    if (info && !TWACVisible(info)) continue;
                    [ids addObject:bid];
                } @catch (__unused NSException *e) {}
            }
        }
    } @catch (__unused NSException *e) {}
    NSMutableOrderedSet *roots = [NSMutableOrderedSet orderedSetWithArray:@[@"/Applications", @"/System/Applications", @"/var/mobile/Containers/Bundle/Application", @"/var/containers/Bundle/Application", @"/var/jb/Applications"]];
    for (NSString *root in TWJBRootCandidates()) [roots addObject:TWJoinPath(root, @"Applications")];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *base in roots) {
        for (NSString *child in [fm contentsOfDirectoryAtPath:base error:nil]) {
            NSString *candidate = [base stringByAppendingPathComponent:child];
            if ([child.pathExtension.lowercaseString isEqual:@"app"]) { TWACBundle(candidate, ids); continue; }
            // Container roots have UUID directories with one .app child. No recursive scan.
            if (![base hasSuffix:@"/Bundle/Application"]) continue;
            for (NSString *name in [fm contentsOfDirectoryAtPath:candidate error:nil])
                if ([name.pathExtension.lowercaseString isEqual:@"app"]) TWACBundle([candidate stringByAppendingPathComponent:name], ids);
        }
    }
    return [ids.array sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

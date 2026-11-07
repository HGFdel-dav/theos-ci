#if __has_include(<rootless.h>)
#import <rootless.h>
#define jbRootPath(path) ROOT_PATH_NS(path)
#else
#define jbRootPath(path) (path)
#endif

static NSString *const kSuiteName = @"com.guacforlife.reynarddefaultprefs";
static NSString *const kEnabledKey = @"enabled";
static NSString *const kSystemLinksKey = @"externalLinksToSystem";
static NSString *const kHandoffKey = @"handoffExternalLinks";

@interface NSDistributedNotificationCenter : NSNotificationCenter
@end

// Reads a boolean from the shared preference domain.
// The springboard tweak, the preference bundle and the injected app dylib all
// live in different sandboxes, so go through CFPreferences (cfprefsd serves it)
// instead of assuming a container-relative path.
static inline BOOL RDReadBoolPref(NSString *key, BOOL fallback) {
    Boolean ok = false;
    CFPropertyListRef value = CFPreferencesCopyValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kSuiteName,
                                                    kCFPreferencesCurrentUser,
                                                    kCFPreferencesAnyHost);
    if (!value) {
        value = CFPreferencesCopyValue((__bridge CFStringRef)key,
                                       (__bridge CFStringRef)kSuiteName,
                                       kCFPreferencesAnyUser,
                                       kCFPreferencesAnyHost);
    }
    if (!value) {
        NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
        id object = [prefs objectForKey:key];
        if (!object) return fallback;
        return [object boolValue];
    }
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        ok = CFBooleanGetValue((CFBooleanRef)value) ? true : false;
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int number = 0;
        ok = CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number) && number != 0;
    }
    CFRelease(value);
    return ok ? YES : NO;
}

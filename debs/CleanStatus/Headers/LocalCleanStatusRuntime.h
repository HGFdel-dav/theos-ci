#pragma once
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <string.h>
#import <stdlib.h>

#if CLEANSTATUS_STRIP_LOGS
#define NSLog(...) do {} while (0)
#define syslog(...) do {} while (0)
#endif

static inline const char *local_cleanstatus_skipQualifiers(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}
static inline BOOL local_cleanstatus_typeMatches(const char *actual, const char *expected) {
    actual = local_cleanstatus_skipQualifiers(actual); expected = local_cleanstatus_skipQualifiers(expected);
    if (!actual || !expected) return NO;
    if (strcmp(actual, expected) == 0) return YES;
    // BOOL was historically signed char; both are a single-byte ABI.
    if ((strcmp(actual, "B") == 0 || strcmp(actual, "c") == 0) &&
        (strcmp(expected, "B") == 0 || strcmp(expected, "c") == 0)) return YES;
    // Object class names in encodings do not change the Objective-C id ABI.
    return actual[0] == '@' && actual[1] != '?' && expected[0] == '@' && expected[1] != '?';
}
static inline BOOL local_cleanstatus_methodMatches(Class cls, SEL selector, const char *result,
                                    unsigned count, const char * const *arguments) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != count + 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL match = local_cleanstatus_typeMatches(type, result); free(type);
    for (unsigned i = 0; match && i < count; i++) {
        type = method_copyArgumentType(method, i + 2);
        match = local_cleanstatus_typeMatches(type, arguments[i]); free(type);
    }
    return match;
}
static inline BOOL local_cleanstatus_canCall(id object, SEL selector, const char *result) {
    return object && local_cleanstatus_methodMatches(object_getClass(object), selector, result, 0, NULL);
}
static inline id local_cleanstatus_object(id object, const char *name) {
    SEL selector = sel_registerName(name);
    return local_cleanstatus_canCall(object, selector, @encode(id)) ? ((id(*)(id,SEL))objc_msgSend)(object,selector) : nil;
}
static inline BOOL local_cleanstatus_boolValue(id object, const char *name, BOOL fallback) {
    SEL selector = sel_registerName(name);
    return local_cleanstatus_canCall(object,selector,@encode(BOOL)) ? ((BOOL(*)(id,SEL))objc_msgSend)(object,selector) : fallback;
}
static inline NSInteger local_cleanstatus_integer(id object, const char *name, NSInteger fallback) {
    SEL selector = sel_registerName(name);
    return local_cleanstatus_canCall(object,selector,@encode(NSInteger)) ? ((NSInteger(*)(id,SEL))objc_msgSend)(object,selector) : fallback;
}
static inline double local_cleanstatus_double(id object, const char *name, double fallback) {
    SEL selector = sel_registerName(name);
    return local_cleanstatus_canCall(object,selector,@encode(double)) ? ((double(*)(id,SEL))objc_msgSend)(object,selector) : fallback;
}
static inline BOOL local_cleanstatus_inStatusBar(UIView *view) {
    // Do not touch battery widgets, Settings previews or arbitrary app icons.
    for (UIView *node = view.superview; node; node = node.superview) {
        NSString *name = NSStringFromClass(node.class);
        if ([name hasPrefix:@"_UIStatusBar"] || [name hasPrefix:@"UIStatusBar"]) return YES;
    }
    return NO;
}
FOUNDATION_EXPORT void local_cleanstatus_installStatusHooks(void);
FOUNDATION_EXPORT void local_cleanstatus_installUnknownPartsHooks(void);
FOUNDATION_EXPORT void local_cleanstatus_refreshStatusBars(void);
FOUNDATION_EXPORT void local_cleanstatus_installBatteryHooks(void);
FOUNDATION_EXPORT void local_cleanstatus_refreshBatteries(void);
FOUNDATION_EXPORT void local_cleanstatus_installLowPowerBridge(void);
FOUNDATION_EXPORT void local_cleanstatus_requestLowPowerToggle(void);
FOUNDATION_EXPORT void local_cleanstatus_installControlCenterHooks(void);

#import "PXCloneRuntime.h"
#import <objc/message.h>
#import <dlfcn.h>
#include <string.h>

static BOOL PXMatchSignature(NSMethodSignature *signature,
                             const char *returnType,
                             NSArray<NSString *> * _Nullable argumentTypes,
                             NSUInteger expectedArguments) {
    if (!signature || !returnType) return NO;
    if (signature.numberOfArguments != expectedArguments + 2) return NO;
    if (strcmp(signature.methodReturnType, returnType) != 0) return NO;
    if (!argumentTypes) return YES;
    if (argumentTypes.count != expectedArguments) return NO;
    for (NSUInteger i = 0; i < expectedArguments; i++) {
        const char *actual = [signature getArgumentTypeAtIndex:i + 2];
        const char *expected = argumentTypes[i].UTF8String;
        if (!actual || !expected) return NO;
        if (expected[0] == '@' && expected[1] == '\0') {
            // An object is fine, but not an ObjC block (also '@?').
            if (actual[0] != '@' || actual[1] == '?') return NO;
        } else if (strcmp(actual, expected) != 0) {
            return NO;
        }
    }
    return YES;
}

BOOL PXCloneClassResponds(Class cls, SEL selector) {
    return cls && selector && [cls respondsToSelector:selector];
}

BOOL PXCloneClassMethodMatches(Class cls, SEL selector,
                               const char *returnType,
                               NSArray<NSString *> *argumentTypes,
                               NSUInteger *argumentCount) {
    if (!cls || !selector || ![cls respondsToSelector:selector]) return NO;
    Method method = class_getClassMethod(cls, selector);
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    BOOL ok = PXMatchSignature(signature, returnType, argumentTypes,
                               argumentCount ? *argumentCount : argumentTypes.count);
    if (ok && argumentCount) *argumentCount = signature.numberOfArguments - 2;
    return ok;
}

BOOL PXCloneInstanceMethodMatches(id target, SEL selector,
                                  const char *returnType,
                                  NSArray<NSString *> *argumentTypes) {
    if (!target || !selector || ![target respondsToSelector:selector]) return NO;
    Method method = class_getInstanceMethod(object_getClass(target), selector);
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    return PXMatchSignature(signature, returnType, argumentTypes, argumentTypes.count);
}

BOOL PXCloneClassInstanceMethodMatches(Class cls, SEL selector,
                                       const char *returnType,
                                       NSArray<NSString *> *argumentTypes) {
    if (!cls || !selector) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    return PXMatchSignature(signature, returnType, argumentTypes, argumentTypes.count);
}

id PXCloneSendId(id target, SEL selector) {
    if (!target || !selector) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

id PXCloneSendId1(id target, SEL selector, id argument) {
    if (!target || !selector) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, argument); }
    @catch (__unused NSException *exception) { return nil; }
}

BOOL PXCloneSendBool(id target, SEL selector) {
    if (!target || !selector) return NO;
    @try { return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector) != 0; }
    @catch (__unused NSException *exception) { return NO; }
}

BOOL PXCloneSendBool1(id target, SEL selector, id argument) {
    if (!target || !selector) return NO;
    @try { return ((BOOL (*)(id, SEL, id))objc_msgSend)(target, selector, argument) != 0; }
    @catch (__unused NSException *exception) { return NO; }
}

void PXCloneSendVoid(id target, SEL selector) {
    if (!target || !selector) return;
    @try { ((void (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { }
}

void PXCloneSendVoid1(id target, SEL selector, id argument) {
    if (!target || !selector) return;
    @try { ((void (*)(id, SEL, id))objc_msgSend)(target, selector, argument); }
    @catch (__unused NSException *exception) { }
}

uintptr_t PXCloneImageBase(const void *anchor) {
    if (!anchor) return 0;
    Dl_info info;
    if (!dladdr(anchor, &info) || !info.dli_fbase) return 0;
    return (uintptr_t)info.dli_fbase;
}

void *PXCloneFunctionAt(const void *anchor, uintptr_t offset) {
    uintptr_t base = PXCloneImageBase(anchor);
    return base ? (void *)(base + offset) : NULL;
}

BOOL PXCloneHookMessage(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls || !selector || !replacement) return NO;
    typedef void (*PXMSHookMessageEx)(Class, SEL, IMP, IMP *);
    static PXMSHookMessageEx hook;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hook = (PXMSHookMessageEx)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    });
    if (!hook) return NO;
    hook(cls, selector, replacement, original);
    return YES;
}

BOOL PXCloneHookFunction(void *target, void *replacement, void **original) {
    if (!target || !replacement) return NO;
    typedef void (*PXMSHookFunction)(void *, void *, void **);
    static PXMSHookFunction hook;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hook = (PXMSHookFunction)dlsym(RTLD_DEFAULT, "MSHookFunction");
    });
    if (!hook) return NO;
    hook(target, replacement, original);
    return YES;
}

// CXPXRuntime.h — alpha342 的 ObjC API 与已核证 Swift 对象字段。
// 元数据：PXPanelEntry 的 Swift ivar type 为空；String? 是16字节，绝不能按 id 读。
// 只读白名单中的8字节 ObjC 引用，偏移由运行时取得，不硬编码偏移。
#pragma once
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>

static inline id CXPXGetObject(id target, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!target || ![target respondsToSelector:sel]) return nil;
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments != 2 || sig.methodReturnType[0] != '@' ||
            sig.methodReturnType[1] == '?') return nil;
        return ((id (*)(id, SEL))objc_msgSend)(target, sel);
    } @catch (__unused NSException *e) { return nil; }
}

static inline size_t CXPXFieldSpan(Class cls, Ivar ivar) {
    ptrdiff_t offset = ivar_getOffset(ivar);
    ptrdiff_t end = (ptrdiff_t)class_getInstanceSize(cls);
    unsigned int count = 0;
    Ivar *fields = class_copyIvarList(cls, &count);
    if (!fields) return 0;
    for (unsigned int i = 0; i < count; i++) {
        ptrdiff_t next = ivar_getOffset(fields[i]);
        if (next > offset && next < end) end = next;
    }
    free(fields);
    return offset >= 0 && end > offset ? (size_t)(end - offset) : 0;
}

static inline id CXPXEntryObject(id entry, const char *name, Class expectedClass) {
    Class px = NSClassFromString(@"PXPanelEntry");
    if (!entry || !px || ![entry isKindOfClass:px] || !expectedClass || !name) return nil;
    BOOL allowed = NO;
    for (NSString *field in @[@"activeBridge", @"hostWindow", @"hostCard", @"hostCanvas",
                              @"handleWindow", @"handle", @"leftHandle"]) {
        if (strcmp(name, field.UTF8String) == 0) { allowed = YES; break; }
    }
    if (!allowed) return nil;
    Ivar ivar = class_getInstanceVariable(px, name);
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    id value = nil;
    if (type && type[0] == '@') {
        value = object_getIvar(entry, ivar);
    } else {
        // alpha342 这些字段的 Swift Optional<ObjCClass> 存储就是一个可空对象指针。
        // 严格限制空type、8字节槽与界限；不读取原生String/tuple/标量。
        ptrdiff_t offset = ivar_getOffset(ivar);
        if ((type && type[0]) || CXPXFieldSpan(px, ivar) != sizeof(id) ||
            offset < 0 || (size_t)offset + sizeof(id) > class_getInstanceSize(px)) return nil;
        id __unsafe_unretained raw = nil;
        const uint8_t *bytes = (const uint8_t *)(__bridge const void *)entry;
        memcpy(&raw, bytes + offset, sizeof(raw));
        value = raw;
    }
    return [value isKindOfClass:expectedClass] ? value : nil;
}

static inline BOOL CXPXEntryFlag(id entry, const char *name) {
    Class px = NSClassFromString(@"PXPanelEntry");
    if (!entry || !px || ![entry isKindOfClass:px] || !name) return NO;
    if (strcmp(name, "fullscreenToWindowInProgress") &&
        strcmp(name, "fullscreenLaunchInProgress") && strcmp(name, "deviceLocked")) return NO;
    Ivar field = class_getInstanceVariable(px, name);
    if (!field) return NO;
    ptrdiff_t offset = ivar_getOffset(field);
    const char *type = ivar_getTypeEncoding(field);
    if (offset < 0 || (size_t)offset >= class_getInstanceSize(px) ||
        (type && type[0] && strcmp(type, @encode(BOOL)) != 0)) return NO;
    uint8_t value = 0;
    const uint8_t *bytes = (const uint8_t *)(__bridge const void *)entry;
    memcpy(&value, bytes + offset, 1);
    return value == 1;
}

static inline BOOL CXPXVoidSelector(id target, NSString *name, NSUInteger argumentCount) {
    SEL sel = NSSelectorFromString(name);
    if (!target || ![target respondsToSelector:sel]) return NO;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments != argumentCount + 2 ||
        strcmp(sig.methodReturnType, @encode(void)) != 0) return NO;
    for (NSUInteger i = 2; i < sig.numberOfArguments; i++)
        if ([sig getArgumentTypeAtIndex:i][0] != '@') return NO;
    return YES;
}

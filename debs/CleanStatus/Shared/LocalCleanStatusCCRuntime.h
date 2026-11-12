#pragma once
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdlib.h>
#include <string.h>

static inline const char *lcscc_type(const char *s) {
    while (s && *s && strchr("rnNoORV",*s)) s++;
    return s;
}
static inline BOOL lcscc_typeEqual(const char *a,const char *b) {
    a=lcscc_type(a); b=lcscc_type(b);
    if (!a || !b) return NO;
    if (!strcmp(a,b)) return YES;
    if ((a[0]=='B'||a[0]=='c') && (b[0]=='B'||b[0]=='c') && !a[1] && !b[1]) return YES;
    return a[0]=='@' && b[0]=='@' && a[1]!='?' && b[1]!='?';
}
// Instance methods use class_getInstanceMethod, class methods use
// class_getClassMethod. Mixing them silently rejects a real method, which is
// exactly how the respring action was reported as unsupported.
static inline BOOL lcscc_classMethod(Class cls,SEL sel,const char *result,unsigned count,const char * const *args) {
    Method m=cls?class_getClassMethod(cls,sel):NULL;
    if (!m || method_getNumberOfArguments(m)!=count+2) return NO;
    char *t=method_copyReturnType(m); BOOL ok=lcscc_typeEqual(t,result); free(t);
    for (unsigned i=0;ok&&i<count;i++) {
        t=method_copyArgumentType(m,i+2); ok=lcscc_typeEqual(t,args[i]); free(t);
    }
    return ok;
}
static inline BOOL lcscc_method(Class cls,SEL sel,const char *result,unsigned count,const char * const *args) {
    Method m=cls?class_getInstanceMethod(cls,sel):NULL;
    if (!m || method_getNumberOfArguments(m)!=count+2) return NO;
    char *t=method_copyReturnType(m); BOOL ok=lcscc_typeEqual(t,result); free(t);
    for (unsigned i=0;ok&&i<count;i++) {
        t=method_copyArgumentType(m,i+2); ok=lcscc_typeEqual(t,args[i]); free(t);
    }
    return ok;
}
static inline BOOL lcscc_can(id obj,const char *name,const char *result) {
    return obj && lcscc_method(object_getClass(obj),sel_registerName(name),result,0,NULL);
}
static inline id lcscc_object(id obj,const char *name) {
    return lcscc_can(obj,name,@encode(id))?((id(*)(id,SEL))objc_msgSend)(obj,sel_registerName(name)):nil;
}
static inline BOOL lcscc_bool(id obj,const char *name,BOOL fallback) {
    return lcscc_can(obj,name,@encode(BOOL))?((BOOL(*)(id,SEL))objc_msgSend)(obj,sel_registerName(name)):fallback;
}

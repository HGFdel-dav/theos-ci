#import "PXPRuntime.h"
#include <string.h>
#include <dlfcn.h>
static const char *PXPUnqualified(const char *s) {
    while (s && *s && strchr("rnNoORV", *s)) ++s;
    return s ?: "";
}
static BOOL PXPType(const char *actual, const char *expected) {
    actual = PXPUnqualified(actual); expected = PXPUnqualified(expected);
    if (!strcmp(expected, "@")) return actual[0] == '@' && actual[1] != '?';
    if (!strcmp(expected, "B")) return !strcmp(actual,"B") || !strcmp(actual,"c");
    return !strcmp(actual, expected);
}
static BOOL PXPMethodSignature(Method method,const char *ret,NSArray<NSString *> *args) {
    if(!method) return NO;
    const char *types=method_getTypeEncoding(method);
    if(!types) return NO;
    NSMethodSignature *s=[NSMethodSignature signatureWithObjCTypes:types];
    if(!s || s.numberOfArguments!=args.count+2 || !PXPType(s.methodReturnType,ret)) return NO;
    if(!PXPType([s getArgumentTypeAtIndex:0],"@") || strcmp([s getArgumentTypeAtIndex:1],":")) return NO;
    for(NSUInteger i=0;i<args.count;++i)
        if(!PXPType([s getArgumentTypeAtIndex:i+2],args[i].UTF8String)) return NO;
    return YES;
}
BOOL PXPInstanceSignature(Class cls,NSString *name,const char *ret,NSArray<NSString *> *args) {
    return cls && PXPMethodSignature(class_getInstanceMethod(cls,NSSelectorFromString(name)),ret,args);
}
BOOL PXPSignature(id o, SEL sel, const char *ret, NSArray<NSString *> *args) {
    if (!o || !sel || ![o respondsToSelector:sel]) return NO;
    return PXPMethodSignature(class_getInstanceMethod(object_getClass(o),sel),ret,args);
}
id PXPGet(id o, NSString *name) {
    SEL s=NSSelectorFromString(name);
    return PXPSignature(o,s,"@",@[]) ? ((id(*)(id,SEL))objc_msgSend)(o,s) : nil;
}
BOOL PXPObjectGetterHasValue(id o,NSString *name,BOOL *known) {
    SEL sel=NSSelectorFromString(name);
    BOOL valid=PXPSignature(o,sel,"@",@[]) || PXPSignature(o,sel,"@?",@[]);
    if(known) *known=valid;
    // Getter is borrowed (+0), whether its return is id or block. No invocation
    // of the returned block is attempted, so no nested block ABI is guessed.
    return valid && ((id(*)(id,SEL))objc_msgSend)(o,sel)!=nil;
}
BOOL PXPBool(id o, NSString *name, BOOL *known) {
    SEL s=NSSelectorFromString(name); BOOL valid=PXPSignature(o,s,"B",@[]);
    if (known) *known=valid;
    return valid ? ((BOOL(*)(id,SEL))objc_msgSend)(o,s) : NO;
}
NSString *PXPString(id o) { return [o isKindOfClass:NSString.class] && [o length] ? o : nil; }
BOOL PXPSetObject(id o, NSString *name, id value) {
    SEL s=NSSelectorFromString(name); if (!PXPSignature(o,s,"v",@[@"@"])) return NO;
    ((void(*)(id,SEL,id))objc_msgSend)(o,s,value); return YES;
}
BOOL PXPSetBool(id o, NSString *name, BOOL value) {
    SEL s=NSSelectorFromString(name); if (!PXPSignature(o,s,"v",@[@"B"])) return NO;
    ((void(*)(id,SEL,BOOL))objc_msgSend)(o,s,value); return YES;
}
BOOL PXPCall(id o, NSString *name) {
    SEL s=NSSelectorFromString(name); if (!PXPSignature(o,s,"v",@[])) return NO;
    ((void(*)(id,SEL))objc_msgSend)(o,s); return YES;
}
NSError *PXPError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.niubiprass.pxpayment" code:code
        userInfo:@{NSLocalizedDescriptionKey:message ?: @"Payment routing stopped"}];
}
BOOL PXPHook(Class cls, NSString *name, IMP replacement, IMP *original,
             const char *ret, NSArray<NSString *> *args) {
    if (!cls || !original || *original) return NO;
    SEL sel=NSSelectorFromString(name); Method method=class_getInstanceMethod(cls,sel);
    if (!PXPMethodSignature(method,ret,args)) return NO;
    void (*hook)(Class,SEL,IMP,IMP*)=dlsym(RTLD_DEFAULT,"MSHookMessageEx");
    if (!hook) return NO;
    hook(cls,sel,replacement,original);
    return *original != NULL;
}

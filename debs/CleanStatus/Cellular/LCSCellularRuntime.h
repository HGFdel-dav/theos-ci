#pragma once
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "LCSCellularPolicy.h"
#include <stdlib.h>

static inline BOOL LCSCellularMethod(Class cls,SEL sel,const char *result,unsigned count,const char *const *args) {
    Method m=cls?class_getInstanceMethod(cls,sel):NULL;
    if(!m||method_getNumberOfArguments(m)!=count+2)return NO;
    char *t=method_copyReturnType(m);BOOL ok=LCSCellularTypeEqual(t,result);free(t);
    for(unsigned i=0;ok&&i<count;i++){t=method_copyArgumentType(m,i+2);ok=LCSCellularTypeEqual(t,args[i]);free(t);}
    return ok;
}
static inline BOOL LCSCellularClassMethod(Class cls,SEL sel,const char *result,unsigned count,const char *const *args) {
    return cls&&LCSCellularMethod(object_getClass(cls),sel,result,count,args);
}
static inline id LCSCellularObject(id object,const char *name) {
    SEL sel=sel_registerName(name);
    return object&&LCSCellularMethod(object_getClass(object),sel,"@",0,NULL)?((id(*)(id,SEL))objc_msgSend)(object,sel):nil;
}
static inline BOOL LCSCellularBool(id object,const char *name,BOOL *known) {
    SEL sel=sel_registerName(name);BOOL valid=object&&LCSCellularMethod(object_getClass(object),sel,"B",0,NULL);
    if(known)*known=valid;
    return valid?((bool(*)(id,SEL))objc_msgSend)(object,sel):NO;
}
static inline long long LCSCellularSlot(id context) {
    SEL sel=sel_registerName("slotID");
    return context&&LCSCellularMethod(object_getClass(context),sel,"q",0,NULL)?((long long(*)(id,SEL))objc_msgSend)(context,sel):0;
}
static inline NSString *LCSCellularString(id object) {
    if(![object isKindOfClass:NSString.class])return nil;
    NSString *s=[object stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length&&s.length<=256?s:nil;
}

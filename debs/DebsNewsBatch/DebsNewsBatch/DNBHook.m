//
//  DNBHook.m
//  DebsNewsBatch
//

#import "DNBHook.h"
#import "DNBCommon.h"

IMP DNBHookInstanceMethod(Class cls, SEL sel, IMP newImp)
{
    if (!cls || !sel || !newImp) {
        return NULL;
    }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        DNBLog(@"挂钩失败：%@ 没有实例方法 %@", NSStringFromClass(cls), NSStringFromSelector(sel));
        return NULL;
    }
    IMP old = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return old;
}

IMP DNBHookClassMethod(Class cls, SEL sel, IMP newImp)
{
    if (!cls || !sel || !newImp) {
        return NULL;
    }
    Method m = class_getClassMethod(cls, sel);
    if (!m) {
        DNBLog(@"挂钩失败：%@ 没有类方法 %@", NSStringFromClass(cls), NSStringFromSelector(sel));
        return NULL;
    }
    IMP old = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return old;
}

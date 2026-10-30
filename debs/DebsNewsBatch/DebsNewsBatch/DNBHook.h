//
//  DNBHook.h
//  DebsNewsBatch
//
//  极小的 runtime 挂钩封装：只用 runtime（method_getImplementation / method_setImplementation），
//  不链接 substrate，保证 dylib 依旧可以 TrollFools 直接注入。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

/* 挂钩实例方法，返回原实现（失败返回 NULL） */
FOUNDATION_EXPORT IMP DNBHookInstanceMethod(Class cls, SEL sel, IMP newImp);

/* 挂钩类方法，返回原实现 */
FOUNDATION_EXPORT IMP DNBHookClassMethod(Class cls, SEL sel, IMP newImp);

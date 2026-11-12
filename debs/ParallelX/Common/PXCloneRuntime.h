#pragma once
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

// Strict ABI/prologue guard around Swift-backed and private ObjC surfaces.
// An object/scalar confusion must fail closed instead of calling a guessed IMP.
BOOL PXCloneClassMethodMatches(Class cls, SEL selector,
                               const char *returnType,
                               NSArray<NSString *> * _Nullable argumentTypes,
                               NSUInteger * _Nullable argumentCount);
BOOL PXCloneInstanceMethodMatches(id target, SEL selector,
                                  const char *returnType,
                                  NSArray<NSString *> * _Nullable argumentTypes);
BOOL PXCloneClassInstanceMethodMatches(Class cls, SEL selector,
                                       const char *returnType,
                                       NSArray<NSString *> * _Nullable argumentTypes);
BOOL PXCloneClassResponds(Class cls, SEL selector);

// Exception-guarded sends, only after a guard above returned YES.
id _Nullable PXCloneSendId(id target, SEL selector);
id _Nullable PXCloneSendId1(id target, SEL selector, id argument);
BOOL PXCloneSendBool(id target, SEL selector);
BOOL PXCloneSendBool1(id target, SEL selector, id argument);
void PXCloneSendVoid(id target, SEL selector);
void PXCloneSendVoid1(id target, SEL selector, id argument);

// Resolves a function inside the image that contains `anchor`; 0 on failure.
uintptr_t PXCloneImageBase(const void *anchor);
void * _Nullable PXCloneFunctionAt(const void *anchor, uintptr_t offset);

// Resolves Substrate dynamically so a missing library fails closed.
BOOL PXCloneHookFunction(void *target, void *replacement, void * _Nullable * _Nullable original);
BOOL PXCloneHookMessage(Class cls, SEL selector, IMP replacement, IMP _Nullable * _Nullable original);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif

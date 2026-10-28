#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Every private call must match the actual runtime method, including argument types.
BOOL PXPSignature(id obj, SEL sel, const char *ret, NSArray<NSString *> *args);
BOOL PXPInstanceSignature(Class cls, NSString *name, const char *ret, NSArray<NSString *> *args);
id PXPGet(id obj, NSString *name);
BOOL PXPObjectGetterHasValue(id obj, NSString *name, BOOL *known);
BOOL PXPBool(id obj, NSString *name, BOOL *known);
NSString *PXPString(id obj);
BOOL PXPSetObject(id obj, NSString *name, id value);
BOOL PXPSetBool(id obj, NSString *name, BOOL value);
BOOL PXPCall(id obj, NSString *name);
NSError *PXPError(NSInteger code, NSString *message);
BOOL PXPHook(Class cls, NSString *name, IMP replacement, IMP *original,
             const char *ret, NSArray<NSString *> *args);

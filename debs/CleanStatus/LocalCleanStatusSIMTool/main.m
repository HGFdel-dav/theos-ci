#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Security/Security.h>
#import "../Cellular/LCSCellularRuntime.h"
#import "../Cellular/LCSCellularSettings.h"
#import <dlfcn.h>
#include <stdint.h>
#include <notify.h>
#include <unistd.h>
#include <signal.h>

// Exit 0 means request accepted, NOT final radio state. The caller must read back.
// No output contains an ICCID, plan description, phone number or raw exception.
static BOOL LCSHelperUnlocked(void) {
    static void *library;static int (*readState)(CFDictionaryRef);
    if(!library){library=dlopen("/System/Library/PrivateFrameworks/MobileKeyBag.framework/MobileKeyBag",RTLD_NOW|RTLD_LOCAL);if(library)readState=(int(*)(CFDictionaryRef))dlsym(library,"MKBGetDeviceLockState");}
    // Only the unlocked value 0 is accepted. Disabled, locked, errors and unavailable
    // interfaces all fail closed. Exact iOS15.5 permission/lock semantics need a device test.
    if(!readState||readState(NULL)!=0)return NO;
    int token=0;uint64_t state=UINT64_MAX;
    if(notify_register_check("com.apple.springboard.lockstate",&token)!=NOTIFY_STATUS_OK)return NO;
    uint32_t result=notify_get_state(token,&state);notify_cancel(token);
    return result==NOTIFY_STATUS_OK&&state==0;
}
static BOOL LCSHelperParent(void) {
    int (*readPath)(int,void *,uint32_t)=(int(*)(int,void *,uint32_t))dlsym(RTLD_DEFAULT,"proc_pidpath");
    if(!readPath)return NO;
    char path[4096]={0}; // libproc's bounded path API; unavailable symbol rejects the request.
    if(readPath((int)getppid(),path,(uint32_t)sizeof(path))<=0)return NO;
    path[sizeof(path)-1]=0;
    NSString *image=[NSString stringWithUTF8String:path];
    return [image isEqualToString:@"/System/Library/CoreServices/SpringBoard.app/SpringBoard"];
}
static BOOL LCSHelperGate(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion==15&&LCSHelperParent()&&
        [LCSCellularReadPreferences()[@"simManager"] boolValue]&&LCSHelperUnlocked();
}
static NSArray *LCSHelperPlans(id manager) {
    SEL sel=sel_registerName("planItemsShouldUpdate:");const char *args[]={"B"};
    if(!LCSCellularMethod(object_getClass(manager),sel,"@",1,args))return nil;
    id values=((id(*)(id,SEL,bool))objc_msgSend)(manager,sel,true);
    return [values isKindOfClass:NSArray.class]?values:nil;
}
static NSString *LCSHelperUUIDString(id value) {
    if([value isKindOfClass:NSUUID.class])return [value UUIDString].lowercaseString;
    NSString *s=LCSCellularString(value);
    return s&&[[NSUUID alloc] initWithUUIDString:s]?s.lowercaseString:nil;
}
static NSString *LCSHelperPlanUUID(id manager,id plan) {
    SEL sel=sel_registerName("getSubscriptionContextUUIDforPlan:");const char *args[]={"@"};
    if(LCSCellularMethod(object_getClass(manager),sel,"@",1,args)) {
        NSString *uuid=LCSHelperUUIDString(((id(*)(id,SEL,id))objc_msgSend)(manager,sel,plan));if(uuid)return uuid;
    }
    return LCSHelperUUIDString(LCSCellularObject(plan,"uuid"));
}
static id LCSHelperUnique(id manager,NSArray *plans,NSString *identity) {
    id result=nil;NSUInteger matches=0;
    for(id plan in plans)if([LCSHelperPlanUUID(manager,plan) isEqualToString:identity]){result=plan;matches++;}
    return matches==1?result:nil;
}
static BOOL LCSHelperPlanUsable(id plan) {
    BOOL displayKnown=NO,installKnown=NO,selectedKnown=NO;
    BOOL display=LCSCellularBool(plan,"shouldDisplay",&displayKnown);
    BOOL installing=LCSCellularBool(plan,"isInstalling",&installKnown);
    (void)LCSCellularBool(plan,"isSelected",&selectedKnown);
    return displayKnown&&display&&installKnown&&!installing&&selectedKnown;
}
int main(int argc,char **argv) {
    @autoreleasepool {
        if(argc!=3||!LCSCellularHelperArgumentValid(argv[1],argv[2]))return 64;
        NSString *identity=[[NSString alloc] initWithUTF8String:argv[1]];if(!identity.length)return 64;
        BOOL desired=argv[2][0]=='1';alarm(10); // Bounds a stalled private-framework call in THIS child.
        @try {
            if(!LCSHelperGate())return 67;
            void *framework=dlopen("/System/Library/PrivateFrameworks/CellularPlanManager.framework/CellularPlanManager",RTLD_NOW|RTLD_LOCAL);
            if(!framework)return 68;
            id manager=LCSCellularObject(NSClassFromString(@"CTCellularPlanManager"),"sharedManager");
            SEL write=sel_registerName("didSelectPlanItem:isEnable:");const char *args[]={"@","B"};
            if(!manager||!LCSCellularMethod(object_getClass(manager),write,"@",2,args))return 66;
            NSArray *plans=LCSHelperPlans(manager);if(!plans)return 66;
            id first=LCSHelperUnique(manager,plans,identity);if(!first)return 65;
            if(!LCSHelperPlanUsable(first))return 69;
            // Refresh immediately before committing. No slot/array-index conversion anywhere.
            NSArray *latest=LCSHelperPlans(manager);if(!latest)return 66;
            id target=LCSHelperUnique(manager,latest,identity);if(!target)return 65;
            if(!LCSHelperPlanUsable(target))return 69;
            if(![LCSHelperPlanUUID(manager,target) isEqualToString:identity])return 70;
            if(!LCSHelperGate())return 67;
            BOOL known=NO,already=LCSCellularBool(target,"isSelected",&known);if(!known)return 66;
            if(already==desired)return 0;
            id response=((id(*)(id,SEL,id,bool))objc_msgSend)(manager,write,target,(bool)desired);
            if([response isKindOfClass:NSError.class])return 68;
            if([response isKindOfClass:NSNumber.class]&&![response boolValue])return 68;
            return 0; // nil/other return is not proof of success: caller polls system state.
        } @catch(__unused NSException *exception) {return 68;}
    }
}

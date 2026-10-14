// Verified app selectors: analysis/device-methods.tsv. C hooks never call Foundation.
#import <sys/utsname.h>
#import <errno.h>
#import <dlfcn.h>
typedef struct { const char *name;const char *identifier; } TKDeviceProfile;
static const TKDeviceProfile TKProfiles[]={
    {"iPhone 12","iPhone13,2"},{"iPhone 12 mini","iPhone13,1"},
    {"iPhone 12 Pro","iPhone13,3"},{"iPhone 12 Pro Max","iPhone13,4"},
    {"iPhone 13","iPhone14,5"},{"iPhone 13 mini","iPhone14,4"},
    {"iPhone 13 Pro","iPhone14,2"},{"iPhone 13 Pro Max","iPhone14,3"},
    {"iPhone 14","iPhone14,7"},{"iPhone 14 Plus","iPhone14,8"},
    {"iPhone 14 Pro","iPhone15,2"},{"iPhone 14 Pro Max","iPhone15,3"},
    {"iPhone 15","iPhone15,4"},{"iPhone 15 Plus","iPhone15,5"},
    {"iPhone 15 Pro","iPhone16,1"},{"iPhone 15 Pro Max","iPhone16,2"},
    {"iPhone 16","iPhone17,3"},{"iPhone 16 Plus","iPhone17,4"},
    {"iPhone 16 Pro","iPhone17,1"},{"iPhone 16 Pro Max","iPhone17,2"}
};
static int gTKSpoofIndex=-1;
static unsigned long long gTKHardwareReads;
static int (*TKOriginalSysctlByName)(const char *,void *,size_t *,void *,size_t);
static int (*TKOriginalSysctl)(int *,u_int,void *,size_t *,void *,size_t);
static int (*TKOriginalUname)(struct utsname *);
static void TKRefreshSpoofProfile(void) {
    int index=-1;
    if(prefBool(kEnabled,YES)&&prefBool(kDeviceSpoof,NO)) {
        NSString *name=prefStr(kSpoofModel,@"iPhone 15 Pro");
        for(unsigned i=0;i<sizeof(TKProfiles)/sizeof(TKProfiles[0]);i++)
            if([name caseInsensitiveCompare:[NSString stringWithUTF8String:TKProfiles[i].name]]==NSOrderedSame ||
               [name caseInsensitiveCompare:[NSString stringWithUTF8String:TKProfiles[i].identifier]]==NSOrderedSame){index=(int)i;break;}
    }
    __atomic_store_n(&gTKSpoofIndex,index,__ATOMIC_RELEASE);
}
static const char *TKHardwareIdentifier(void) {
    int index=__atomic_load_n(&gTKSpoofIndex,__ATOMIC_ACQUIRE);
    return index>=0?TKProfiles[index].identifier:NULL;
}
static int TKCopyHardwareValue(void *output,size_t *length,const char *value) {
    if(!length){errno=EFAULT;return -1;}
    size_t required=strlen(value)+1,capacity=*length;*length=required;
    if(!output)return 0;
    if(capacity<required){if(capacity)memcpy(output,value,capacity);errno=ENOMEM;return -1;}
    memcpy(output,value,required);return 0;
}
static int TKSysctlByName(const char *name,void *oldp,size_t *oldlenp,void *newp,size_t newlen) {
    const char *identifier=TKHardwareIdentifier();
    if(identifier&&name&&!strcmp(name,"hw.machine")&&!newp&&!newlen) {
        __atomic_fetch_add(&gTKHardwareReads,1,__ATOMIC_RELAXED);
        return TKCopyHardwareValue(oldp,oldlenp,identifier);
    }
    if(TKOriginalSysctlByName)return TKOriginalSysctlByName(name,oldp,oldlenp,newp,newlen);
    errno=ENOSYS;return -1;
}
static int TKSysctl(int *name,u_int count,void *oldp,size_t *oldlenp,void *newp,size_t newlen) {
    const char *identifier=TKHardwareIdentifier();
    if(identifier&&name&&count==2&&name[0]==CTL_HW&&name[1]==HW_MACHINE&&!newp&&!newlen) {
        __atomic_fetch_add(&gTKHardwareReads,1,__ATOMIC_RELAXED);
        return TKCopyHardwareValue(oldp,oldlenp,identifier);
    }
    if(TKOriginalSysctl)return TKOriginalSysctl(name,count,oldp,oldlenp,newp,newlen);
    errno=ENOSYS;return -1;
}
static int TKUname(struct utsname *result) {
    if(!TKOriginalUname){errno=ENOSYS;return -1;}
    int rc=TKOriginalUname(result),saved=errno;const char *identifier=TKHardwareIdentifier();
    if(rc==0&&result&&identifier){strlcpy(result->machine,identifier,sizeof(result->machine));__atomic_fetch_add(&gTKHardwareReads,1,__ATOMIC_RELAXED);}
    errno=saved;return rc;
}
static id TKDeviceOriginal(id self,SEL cmd) {
    IMP original=NULL;
    if(object_isClass(self)) {
        original=OrigIMP(NSStringFromClass((Class)self),cmd);
    }else original=OrigIMP(@"UIDevice",cmd);
    return original?((id(*)(id,SEL))original)(self,cmd):nil;
}
static NSString *TKDeviceIdentifier(id self,SEL cmd) {
    if(prefBool(kEnabled,YES)&&prefBool(kDeviceSpoof,NO)) {
        const char *identifier=TKHardwareIdentifier();
        if(identifier)return [NSString stringWithUTF8String:identifier];
    }
    return TKDeviceOriginal(self,cmd);
}
static NSString *TKDeviceFriendlyName(id self,SEL cmd) {
    // Always record calls, including active overrides, for runtime verification.
    id actual=TKDeviceOriginal(self,cmd);
    return prefBool(kEnabled,YES)&&prefBool(kDeviceSpoof,NO)?prefStr(kSpoofModel,@"iPhone 15 Pro"):actual;
}
static void TKInstallDeviceHooks(void) {
    TKRefreshSpoofProfile();
    for(NSString *selector in @[@"qq_modelIdentifier",@"platform",@"qq_platform",@"tkp_devicePlatform"])
        InstallHook(@"UIDevice",NSSelectorFromString(selector),(IMP)TKDeviceIdentifier,NO);
    for(NSString *selector in @[@"platformString",@"qq_platformString",@"qq_allTypePlatformString",@"p_devicePlatformString",@"tkp_devicePlatformString"])
        InstallHook(@"UIDevice",NSSelectorFromString(selector),(IMP)TKDeviceFriendlyName,NO);
    InstallHook(@"UIDevice",NSSelectorFromString(@"hippy_platformString"),(IMP)TKDeviceFriendlyName,YES);
    InstallHook(@"DeviceInfoUtil",NSSelectorFromString(@"model"),(IMP)TKDeviceIdentifier,YES);
    InstallHook(@"QAnaDeviceUtil",NSSelectorFromString(@"model"),(IMP)TKDeviceIdentifier,YES);
    InstallHook(@"QAnaDeviceUtil",NSSelectorFromString(@"modelName"),(IMP)TKDeviceFriendlyName,YES);
    static dispatch_once_t once;dispatch_once(&once,^{
        void *symbol=dlsym(RTLD_DEFAULT,"sysctlbyname");if(symbol)MSHookFunction(symbol,(void *)TKSysctlByName,(void **)&TKOriginalSysctlByName);
        symbol=dlsym(RTLD_DEFAULT,"sysctl");if(symbol)MSHookFunction(symbol,(void *)TKSysctl,(void **)&TKOriginalSysctl);
        symbol=dlsym(RTLD_DEFAULT,"uname");if(symbol)MSHookFunction(symbol,(void *)TKUname,(void **)&TKOriginalUname);
    });
}

#import "PXCSettings.h"
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <limits.h>

// Only the UI model's grouping key changes. Never mutate request thread IDs,
// notification identifiers, content, action objects or the notification store.
static BOOL PXCGInstalled;
static BOOL PXCGSessionPolicy;
static BOOL PXCGPolicyLoaded;
static NSUInteger PXCGLogCount;
static NSUInteger PXCGInsertionDepth;
static NSUInteger PXCGRemovalDepth;
static const char *PXCGType(const char *t) { while (t && *t && strchr("rnNoORV",*t)) t++;return t; }
static BOOL PXCGMethod(Class cls,SEL sel,char result,unsigned explicitArgs) {
    Method m=class_getInstanceMethod(cls,sel);if (!m || method_getNumberOfArguments(m)!=explicitArgs+2) return NO;
    char type[64];method_getReturnType(m,type,sizeof(type));char r=*PXCGType(type);
    if (result=='b' ? r!='B' && r!='c' : r!=result) return NO;
    for (unsigned i=0;i<explicitArgs;i++) { method_getArgumentType(m,i+2,type,sizeof(type));if (*PXCGType(type)!='@') return NO; }
    return YES;
}
static id PXCGObject(id o,const char *name) {
    SEL s=sel_registerName(name);if (!o || !PXCGMethod(object_getClass(o),s,'@',0)) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(o,s);
}
static BOOL PXCGClock(id o) {
    SEL s=sel_registerName("isClockNotificationGroup");
    if (!o || !PXCGMethod(object_getClass(o),s,'b',0)) return NO;
    return ((BOOL(*)(id,SEL))objc_msgSend)(o,s);
}
static BOOL PXCGSameApp(id a,id b) {
    id as=PXCGObject(a,"sectionIdentifier"),bs=PXCGObject(b,"sectionIdentifier");
    return [as isKindOfClass:NSString.class] && [as length] && [bs isKindOfClass:NSString.class] && [as isEqual:bs];
}
static BOOL PXCGPolicy(void) {
    if (!PXCGPolicyLoaded) {
        PXCGSessionPolicy=PXCSettingsGet().enabled && PXCSettingsGet().groupByApp;
        PXCGPolicyLoaded=YES;
        PXCLog([NSString stringWithFormat:@"app-group policy=%d latched until SpringBoard reload",PXCGSessionPolicy]);
    }
    return PXCGSessionPolicy;
}
static BOOL PXCGMatchesRequest(id a,id b) {
    if (a==b || [a isEqual:b]) return YES;
    id ai=PXCGObject(a,"notificationIdentifier"),bi=PXCGObject(b,"notificationIdentifier");
    return [ai isKindOfClass:NSString.class] && [ai length] && [ai isEqual:bi] && PXCGSameApp(a,b);
}
static BOOL PXCGContains(id group,id request) {
    id requests=PXCGObject(group,"allNotificationRequests");
    if (![requests isKindOfClass:NSArray.class]) return NO;
    for (id r in requests) if (PXCGMatchesRequest(r,request)) return YES;
    return NO;
}
static unsigned long long PXCGFind(NSArray *groups,id request,BOOL inserting) {
    if (![groups isKindOfClass:NSArray.class] || groups.count>4096 || !request) return ULLONG_MAX;
    // Prefer the real membership for reload/removal, including groups loaded
    // before the policy. Do not remove a same-app sibling by guessed index.
    for (NSUInteger i=0;i<groups.count;i++) if (PXCGContains(groups[i],request)) return i;
    if (inserting) for (NSUInteger i=0;i<groups.count;i++) {
        id g=groups[i];
        if (!PXCGClock(g) && PXCGSameApp(g,request)) return i;
    }
    return ULLONG_MAX;
}
static BOOL (*PXCGOrigIsGroup)(id,SEL,id);
static BOOL PXCGIsGroup(id self,SEL cmd,id request) {
    BOOL native=PXCGOrigIsGroup(self,cmd,request);
    if (NSThread.isMainThread && PXCGRemovalDepth>0) return PXCGContains(self,request);
    if (!NSThread.isMainThread || !PXCGPolicy() || PXCGClock(self)) return native;
    return PXCGSameApp(self,request) ? YES : native;
}
static BOOL (*PXCGOrigMatches)(id,SEL,id);
static BOOL PXCGMatches(id self,SEL cmd,id other) {
    BOOL native=PXCGOrigMatches(self,cmd,other);
    if (!NSThread.isMainThread || !PXCGPolicy() || PXCGClock(self) || PXCGClock(other)) return native;
    return PXCGSameApp(self,other) ? YES : native;
}
static unsigned long long (*PXCGOrigIndex)(id,SEL,id,id,id,id);
static unsigned long long PXCGIndex(id self,SEL cmd,id request,id section,id thread,id groups) {
    unsigned long long native=PXCGOrigIndex(self,cmd,request,section,thread,groups);
    if (!NSThread.isMainThread || !PXCGPolicy()) return native;
    unsigned long long found=PXCGFind(groups,request,PXCGInsertionDepth>0 && PXCGRemovalDepth==0);
    return found==ULLONG_MAX ? native : found;
}
static unsigned long long (*PXCGOrigInsert)(id,SEL,id);
static unsigned long long PXCGInsert(id self,SEL cmd,id request) {
    BOOL scoped=NSThread.isMainThread && PXCGPolicy();
    unsigned long long native;
    if (scoped) PXCGInsertionDepth++;
    @try { native=PXCGOrigInsert(self,cmd,request); }
    @finally { if (scoped) PXCGInsertionDepth--; }
    if (!scoped) return native;
    id groups=PXCGObject(self,"_notificationGroupsForInsertion");
    unsigned long long found=PXCGFind(groups,request,YES);
    if (found!=ULLONG_MAX && found!=native && PXCGLogCount++<20) PXCLog(@"app-group insert rerouted to same-app native group; request preserved");
    return found==ULLONG_MAX ? native : found;
}
static unsigned long long (*PXCGOrigRemove)(id,SEL,id);
static unsigned long long PXCGRemove(id self,SEL cmd,id request) {
    BOOL scoped=NSThread.isMainThread && PXCGPolicy();
    unsigned long long native;
    if (scoped) PXCGRemovalDepth++;
    @try { native=PXCGOrigRemove(self,cmd,request); }
    @finally { if (scoped) PXCGRemovalDepth--; }
    if (!scoped) return native;
    unsigned long long found=PXCGFind(PXCGObject(self,"notificationGroups"),request,NO);
    return found==ULLONG_MAX ? native : found;
}
void PXCAppGroupingInstallHooks(void) {
    if (PXCGInstalled) return;
    Class section=objc_getClass("NCNotificationStructuredSectionList"),group=objc_getClass("NCNotificationGroupList");
    if (!section || !group) return;
    struct { Class cls;const char *sel;char ret;unsigned n;IMP hook;IMP *original; } defs[]={
        {group,"isGroupForNotificationRequest:",'b',1,(IMP)PXCGIsGroup,(IMP *)&PXCGOrigIsGroup},
        {group,"matchesGroup:",'b',1,(IMP)PXCGMatches,(IMP *)&PXCGOrigMatches},
        {section,"_existingIndexOfGroupForNotificationRequest:withSectionIdentifier:threadIdentifier:inNotificationGroupLists:",'Q',4,(IMP)PXCGIndex,(IMP *)&PXCGOrigIndex},
        {section,"_existingIndexOfGroupForNotificationRequestForInsertion:",'Q',1,(IMP)PXCGInsert,(IMP *)&PXCGOrigInsert},
        {section,"_existingIndexOfGroupForNotificationRequestForRemoval:",'Q',1,(IMP)PXCGRemove,(IMP *)&PXCGOrigRemove}
    };
    // Atomic ABI preflight for the entire candidate, not a partial schema.
    for (unsigned i=0;i<sizeof(defs)/sizeof(defs[0]);i++) if (!PXCGMethod(defs[i].cls,sel_registerName(defs[i].sel),defs[i].ret,defs[i].n)) { PXCLog(@"app-group unavailable: method ABI mismatch");return; }
    for (unsigned i=0;i<sizeof(defs)/sizeof(defs[0]);i++) MSHookMessageEx(defs[i].cls,sel_registerName(defs[i].sel),defs[i].hook,defs[i].original);
    PXCGInstalled=YES;PXCLog(@"app-group native UI hooks installed; policy is opt-in, runtime acceptance pending");
}

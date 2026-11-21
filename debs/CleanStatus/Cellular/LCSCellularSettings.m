#import "LCSCellularSettings.h"
#import "LCSCellularRuntime.h"
#import <CoreFoundation/CoreFoundation.h>
#import "../Sources/LocalCleanStatusAnimationPreferences.h"
#include <stdatomic.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>
#include <errno.h>

NSString * const LCSCellularPreferencesDidChange=@"com.local.cleanstatus.cellular-changed";
#ifndef LCS_CELLULAR_STORAGE_TEST
static NSString * const LCSGroup=@"/var/mobile/Containers/Shared/AppGroup";
#endif
static NSString * const LCSRelative=@"var/mobile/Library/Preferences/com.local.cleanstatus.cellular.plist";
static atomic_uint LCSConfiguration=4; // Both features OFF; diagnostic recording ON.
static dispatch_queue_t LCSConfigQueue;

static NSError *LCSError(NSInteger code,NSString *message) {
    return [NSError errorWithDomain:@"com.local.cleanstatus.cellular" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
#ifndef LCS_CELLULAR_STORAGE_TEST
static BOOL LCSHiddenRoot(NSString *root) {
    return root.isAbsolutePath&&[root.stringByDeletingLastPathComponent isEqualToString:LCSGroup]&&
        [root.lastPathComponent hasPrefix:@".jbroot-"]&&root.lastPathComponent.length>8;
}
static BOOL LCSDirectory(NSString *path) {
    struct stat s;return lstat(path.fileSystemRepresentation,&s)==0&&S_ISDIR(s.st_mode);
}
#endif
// Reuse the existing animation store's path discovery, including its .jbroot
// backlink handling for split program/data roots. Do not maintain another resolver.
// Only the sibling cellular filename differs; no animation values are read/written.
NSString *LCSCellularRoot(void) {
    NSString *path=local_cleanstatus_animationPreferencesPath();
    NSString *suffix=@"/var/mobile/Library/Preferences/com.local.cleanstatus.animations.plist";
    if(!path.length||![path hasSuffix:suffix]||path.length<=suffix.length)return nil;
    return [path substringToIndex:path.length-suffix.length];
}
NSString *LCSCellularPreferencesPath(void) {
    NSString *path=local_cleanstatus_animationPreferencesPath();
    if(!path.length||!LCSCellularRoot().length)return nil;
    return [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:LCSRelative.lastPathComponent];
}
NSDictionary *LCSCellularDefaults(void) {return @{@"schema":@1,@"simManager":@NO,@"dataSwitch":@NO,@"diagnostics":@YES};}
static NSDictionary *LCSSanitize(id input) {
    NSDictionary *values=[input isKindOfClass:NSDictionary.class]?input:@{};NSMutableDictionary *result=[LCSCellularDefaults() mutableCopy];
    for(NSString *key in @[@"simManager",@"dataSwitch",@"diagnostics"]) {
        id value=values[key];if([value isKindOfClass:NSNumber.class])result[key]=@([value boolValue]);
    }
    return [result copy];
}
static NSData *LCSRegularData(NSString *path) {
    if(!path.length)return nil;
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return nil;
    struct stat s;NSData *result=nil;
    if(fstat(fd,&s)==0&&S_ISREG(s.st_mode)&&s.st_nlink==1&&s.st_size>0&&s.st_size<=32768) {
        NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)s.st_size];ssize_t count=0;BOOL ok=YES;
        while(count<s.st_size){ssize_t n=read(fd,(char *)data.mutableBytes+count,(size_t)(s.st_size-count));if(n<0&&errno==EINTR)continue;if(n<=0){ok=NO;break;}count+=n;}
        if(ok)result=data;
    }
    close(fd);return result;
}
static NSDictionary *LCSRawPreferences(NSString *path) {
    NSData *data=LCSRegularData(path);
    id values=data?[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL]:nil;
    return [values isKindOfClass:NSDictionary.class]?values:nil;
}
NSDictionary *LCSCellularReadPreferences(void) {return LCSSanitize(LCSRawPreferences(LCSCellularPreferencesPath()));}
static BOOL LCSInside(NSString *path,NSString *root) {
    if(!path.length||!root.length||![path hasPrefix:[root stringByAppendingString:@"/"]]||[path.pathComponents containsObject:@".."])return NO;
    char canonicalRoot[PATH_MAX],canonicalAncestor[PATH_MAX];
    if(!realpath(root.fileSystemRepresentation,canonicalRoot))return NO;
    NSString *ancestor=path.stringByDeletingLastPathComponent;
    while(ancestor.length>1&&![[NSFileManager defaultManager] fileExistsAtPath:ancestor])ancestor=ancestor.stringByDeletingLastPathComponent;
    if(!realpath(ancestor.fileSystemRepresentation,canonicalAncestor))return NO;
    NSString *r=[NSString stringWithUTF8String:canonicalRoot],*a=[NSString stringWithUTF8String:canonicalAncestor];
    return [a isEqualToString:r]||[a hasPrefix:[r stringByAppendingString:@"/"]];
}
static BOOL LCSPrepareDirectory(NSString *path,NSError **error) {
    NSString *root=LCSCellularRoot();struct stat before,after;
    if(!root.length||lstat(root.fileSystemRepresentation,&before)!=0||!S_ISDIR(before.st_mode)||!LCSInside(path,root)) {
        if(error)*error=LCSError(1,@"未找到安全的当前隐根，未写入真实 var。");return NO;
    }
    if(![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error])return NO;
    if(lstat(root.fileSystemRepresentation,&after)!=0||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino||!LCSInside(path,root)) {
        if(error)*error=LCSError(2,@"隐根或目标目录发生变化，未写入。");return NO;
    }
    return YES;
}
static int LCSLock(NSString *name,NSError **error) {
    NSString *file=[LCSCellularPreferencesPath().stringByDeletingLastPathComponent stringByAppendingPathComponent:name];
    if(!LCSPrepareDirectory(file,error))return -1;
    int fd=open(file.fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0600);struct stat s;
    if(fd<0||fstat(fd,&s)!=0||!S_ISREG(s.st_mode)||s.st_nlink!=1||flock(fd,LOCK_EX|LOCK_NB)!=0) {
        if(fd>=0)close(fd);if(error)*error=LCSError(3,@"另一项蜂窝操作正在处理或锁文件不安全。");return -1;
    }
    return fd;
}
int LCSCellularAcquireOperationLock(NSError **error) {return LCSLock(@"com.local.cleanstatus.cellular.operations.lock",error);}
void LCSCellularReleaseOperationLock(int fd) {if(fd>=0){flock(fd,LOCK_UN);close(fd);}}

static BOOL LCSWriteValues(NSDictionary *values,NSError **error) {
    NSString *path=LCSCellularPreferencesPath();if(!LCSPrepareDirectory(path,error))return NO;
    struct stat s;if(lstat(path.fileSystemRepresentation,&s)==0&&(!S_ISREG(s.st_mode)||s.st_nlink!=1)) {
        if(error)*error=LCSError(4,@"设置目标不是普通独立文件，未覆盖。");return NO;
    }
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:LCSSanitize(values) format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if(!data||![data writeToFile:path options:NSDataWritingAtomic error:error])return NO;
    if(![LCSRegularData(path) isEqualToData:data]){if(error)*error=LCSError(5,@"设置写入后读回不一致，未通知运行端。");return NO;}
    return YES;
}
static BOOL LCSMigrateLocked(NSError **error) {
    NSString *target=LCSCellularPreferencesPath();if(!target.length)return NO;
    NSMutableArray *paths=[NSMutableArray arrayWithObject:target];
#ifdef LCS_CELLULAR_STORAGE_TEST
    // Native tests MUST NOT enumerate or clean real var, /var/jb, or a device root.
    NSString *fixture=LCSCellularRoot().stringByDeletingLastPathComponent;
    for(NSString *name in @[@"legacy/one",@"legacy/two"])
        [paths addObject:[[fixture stringByAppendingPathComponent:name] stringByAppendingPathComponent:LCSRelative]];
#else
    BOOL hasHidden=NO;
    // This is the only full scan, used by the panel's explicit migration step.
    for(NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:LCSGroup error:NULL]) {
        NSString *root=[LCSGroup stringByAppendingPathComponent:name];if(!LCSHiddenRoot(root)||!LCSDirectory(root))continue;
        hasHidden=YES;NSString *file=[root stringByAppendingPathComponent:LCSRelative];if(![paths containsObject:file])[paths addObject:file];
    }
    if(!hasHidden)[paths addObject:[@"/var/jb" stringByAppendingPathComponent:LCSRelative]];
    // Real var is only a legacy READ source and is deleted only after safe migration.
    [paths addObject:[@"/" stringByAppendingPathComponent:LCSRelative]];
#endif
    NSString *newest=nil;NSDate *latest=NSDate.distantPast;NSMutableDictionary *snapshots=[NSMutableDictionary dictionary];
    for(NSString *file in paths) {
        NSData *data=LCSRegularData(file);NSDictionary *values=LCSRawPreferences(file);if(!values||!data)continue;
        NSDate *date=[NSFileManager.defaultManager attributesOfItemAtPath:file error:NULL][NSFileModificationDate];
        snapshots[file]=@{@"data":data,@"values":values,@"time":date?:NSDate.distantPast};
        if(!newest||[date compare:latest]==NSOrderedDescending||([date compare:latest]==NSOrderedSame&&[file isEqualToString:target])){newest=file;latest=date?:NSDate.distantPast;}
    }
    if(!newest)return YES;
    NSDictionary *winner=snapshots[newest][@"values"];
    if(![newest isEqualToString:target]&&!LCSWriteValues(winner,error))return NO;
    if(![LCSSanitize(LCSRawPreferences(target)) isEqualToDictionary:LCSSanitize(winner)]) {
        if(error)*error=LCSError(6,@"迁移读回不一致，旧设置保留。");return NO;
    }
    struct stat dst;if(lstat(target.fileSystemRepresentation,&dst)!=0)return NO;
    for(NSString *old in snapshots) {
        struct stat src;if([old isEqualToString:target]||lstat(old.fileSystemRepresentation,&src)!=0||(src.st_dev==dst.st_dev&&src.st_ino==dst.st_ino))continue;
        if(![LCSRegularData(old) isEqualToData:snapshots[old][@"data"]])continue;
        NSDate *now=[NSFileManager.defaultManager attributesOfItemAtPath:old error:NULL][NSFileModificationDate];
        if(![now isEqualToDate:snapshots[old][@"time"]])continue;
        if(unlink(old.fileSystemRepresentation)!=0){if(error)*error=LCSError(7,@"新设置已迁移，旧副本未能清理。");return NO;}
    }
    return YES;
}
// Protected by the settings lock. A failed migration is retryable; a successful one
// is not rerun on each switch write and cannot import a stale root over newer edits.
static BOOL LCSMigrationCompleted=NO;
static BOOL LCSEnsureMigration(NSError **error) {
    if(LCSMigrationCompleted)return YES;
    BOOL ok=LCSMigrateLocked(error);if(ok)LCSMigrationCompleted=YES;return ok;
}
BOOL LCSCellularMigratePreferences(NSError **error) {
    int fd=LCSLock(@"com.local.cleanstatus.cellular.settings.lock",error);if(fd<0)return NO;
    BOOL ok=LCSEnsureMigration(error);LCSCellularReleaseOperationLock(fd);
    if(ok)CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),(__bridge CFStringRef)LCSCellularPreferencesDidChange,NULL,NULL,true);
    return ok;
}
BOOL LCSCellularSaveSetting(NSString *key,BOOL value,NSError **error) {
    if(![@[@"simManager",@"dataSwitch",@"diagnostics"] containsObject:key]){if(error)*error=LCSError(8,@"未知设置项，未保存。");return NO;}
    int fd=LCSLock(@"com.local.cleanstatus.cellular.settings.lock",error);if(fd<0)return NO;
    BOOL ok=LCSEnsureMigration(error);
    if(ok){NSMutableDictionary *values=[LCSCellularReadPreferences() mutableCopy];values[key]=@(value);ok=LCSWriteValues(values,error);}
    LCSCellularReleaseOperationLock(fd);
    if(ok)CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),(__bridge CFStringRef)LCSCellularPreferencesDidChange,NULL,NULL,true);
    return ok;
}
static void LCSReloadConfiguration(void) {
    NSDictionary *p=LCSCellularReadPreferences();unsigned mask=([p[@"simManager"] boolValue]?1U:0U)|([p[@"dataSwitch"] boolValue]?2U:0U)|([p[@"diagnostics"] boolValue]?4U:0U);
    atomic_store_explicit(&LCSConfiguration,mask,memory_order_release);
    dispatch_async(dispatch_get_main_queue(),^{[NSNotificationCenter.defaultCenter postNotificationName:LCSCellularPreferencesDidChange object:nil];});
}
static void LCSChanged(CFNotificationCenterRef center,void *observer,CFStringRef name,const void *object,CFDictionaryRef info) {
    (void)center;(void)observer;(void)name;(void)object;(void)info;
    dispatch_async(LCSConfigQueue,^{LCSReloadConfiguration();});
}
void LCSCellularStartConfiguration(void) {
    static dispatch_once_t once;dispatch_once(&once,^{
        LCSConfigQueue=dispatch_queue_create("com.local.cleanstatus.cellular.config",DISPATCH_QUEUE_SERIAL);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,LCSChanged,(__bridge CFStringRef)LCSCellularPreferencesDidChange,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_async(LCSConfigQueue,^{LCSReloadConfiguration();});
    });
}
BOOL LCSCellularFeatureEnabled(LCSCellularKind kind) {
    LCSCellularStartConfiguration();return LCSCellularKindValid(kind)&&(atomic_load_explicit(&LCSConfiguration,memory_order_acquire)&(1U<<(unsigned)kind))!=0;
}
BOOL LCSCellularIsSpringBoard(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]&&[NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"];
}
BOOL LCSCellularIsUnlocked(void) {
    if(!LCSCellularIsSpringBoard())return NO;
    __block BOOL result=NO;void (^readState)(void)=^{
        Class cls=NSClassFromString(@"SBLockStateAggregator");id object=LCSCellularObject(cls,"sharedInstance");SEL sel=sel_registerName("lockState");
        BOOL valid=LCSCellularMethod(object_getClass(object),sel,"Q",0,NULL)||LCSCellularMethod(object_getClass(object),sel,"q",0,NULL);
        if(object&&valid)result=((((unsigned long long(*)(id,SEL))objc_msgSend)(object,sel))&2U)==0;
    };
    if(NSThread.isMainThread)readState();else dispatch_sync(dispatch_get_main_queue(),readState);
    return result;
}
BOOL LCSCellularMayMutate(LCSCellularKind kind) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion==15&&LCSCellularIsSpringBoard()&&LCSCellularFeatureEnabled(kind)&&LCSCellularIsUnlocked();
}
NSString *LCSCellularSIMToolPath(void) {
    NSString *root=LCSCellularRoot();if(!root.length)return nil;
    // Same direct-or-.jbroot relationship used by the reused animation resolver.
    // A split data root has no usr/; its backlink reaches this installation's code.
    for(NSString *prefix in @[@"",@".jbroot"]) {
        NSString *base=prefix.length?[root stringByAppendingPathComponent:prefix]:root;
        NSString *path=[base stringByAppendingPathComponent:@"usr/libexec/LocalCleanStatus/LocalCleanStatusSIMTool"];
        struct stat s;
        if(lstat(path.fileSystemRepresentation,&s)==0&&S_ISREG(s.st_mode)&&s.st_nlink==1&&access(path.fileSystemRepresentation,X_OK)==0)return path;
    }
    return nil;
}
void LCSCellularLog(LCSCellularKind kind,NSString *event,NSString *reason,NSInteger slot) {
    if(!LCSCellularKindValid(kind)||!(atomic_load_explicit(&LCSConfiguration,memory_order_acquire)&4U))return;
    static NSCharacterSet *bad;static dispatch_once_t once;dispatch_once(&once,^{bad=[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz._-"] invertedSet];});
    // Accept controlled reason slugs only: never raw exceptions, identity or carrier text.
    for(NSString *s in @[event?:@"",reason?:@""])if(!s.length||s.length>48||[s rangeOfCharacterFromSet:bad].location!=NSNotFound)return;
    static dispatch_queue_t queue;static dispatch_once_t queueOnce;dispatch_once(&queueOnce,^{queue=dispatch_queue_create("com.local.cleanstatus.cellular.log",DISPATCH_QUEUE_SERIAL);});
    dispatch_async(queue,^{
        int fd=LCSLock(@"com.local.cleanstatus.cellular.diagnostics.lock",NULL);if(fd<0)return;
        NSString *path=[LCSCellularPreferencesPath().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"com.local.cleanstatus.cellular.diagnostics.plist"];
        NSDictionary *previous=LCSRawPreferences(path);id raw=previous[@"events"];NSMutableArray *events=[raw isKindOfClass:NSArray.class]?[raw mutableCopy]:[NSMutableArray new];
        while(events.count>=128)[events removeObjectAtIndex:0];
        [events addObject:@{@"kind":@(kind),@"event":event,@"reason":reason,@"slot":@(slot>=1&&slot<=2?slot:0),@"time":@(NSDate.date.timeIntervalSince1970)}];
        NSDictionary *payload=@{@"schema":@1,@"events":events};NSData *data=[NSPropertyListSerialization dataWithPropertyList:payload format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        if(data.length<=32768&&LCSPrepareDirectory(path,NULL)){struct stat s;if(lstat(path.fileSystemRepresentation,&s)!=0||(S_ISREG(s.st_mode)&&s.st_nlink==1))[data writeToFile:path options:NSDataWritingAtomic error:NULL];}
        LCSCellularReleaseOperationLock(fd);
    });
}

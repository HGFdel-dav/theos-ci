#import "PXCSettings.h"
#import "PXCPaths.h"
#import <os/log.h>
#import <math.h>
#import <time.h>
#import <errno.h>

extern void PXCDustPrewarm(void);
extern void PXCDustRemoveAll(void);
extern void PXCSlidersRemoveAll(void);
static PXCSettings PXCState = {YES, YES, YES, YES, 1.15, 1};
static dispatch_queue_t PXCLogQueue;
static NSUInteger PXCLogLines;
static void PXCReload(void) {
    NSCAssert(NSThread.isMainThread, @"settings on main");
    NSDictionary *p = PXCReadPreferences();
    PXCSettings s = {YES, YES, YES, YES, 1.15, 1};
    if ([p[@"enabled"] respondsToSelector:@selector(boolValue)]) s.enabled = [p[@"enabled"] boolValue];
    if ([p[@"notifications"] respondsToSelector:@selector(boolValue)]) s.notifications = [p[@"notifications"] boolValue];
    if ([p[@"widgets"] respondsToSelector:@selector(boolValue)]) s.widgets = [p[@"widgets"] boolValue];
    if ([p[@"controlCenter"] respondsToSelector:@selector(boolValue)]) s.controlCenter = [p[@"controlCenter"] boolValue];
    if ([p[@"duration"] respondsToSelector:@selector(doubleValue)]) {
        double t = [p[@"duration"] doubleValue];
        if (isfinite(t)) s.duration = fmax(0.65, fmin(1.8, t));
    }
    if ([p[@"density"] respondsToSelector:@selector(integerValue)]) s.density = (NSUInteger)MAX(0, MIN(2, [p[@"density"] integerValue]));
    PXCState = s;
    PXCRemoveAllEffects();
    if (s.enabled && !UIAccessibilityIsReduceMotionEnabled()) PXCDustPrewarm();
    PXCLog([NSString stringWithFormat:@"config enabled=%d notifications=%d widgets=%d cc=%d duration=%.2f density=%lu", s.enabled,s.notifications,s.widgets,s.controlCenter,s.duration,(unsigned long)s.density]);
}
PXCSettings PXCSettingsGet(void) {
    // All effect/hook callers are main-thread only. Never read plist per frame.
    return PXCState;
}
void PXCRemoveAllEffects(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ PXCRemoveAllEffects(); }); return; }
    PXCDustRemoveAll();
    PXCSlidersRemoveAll();
}
void PXCLog(NSString *message) {
    if (!message.length) return;
    if (!PXCLogQueue) return;
    NSString *line = [message copy];
    dispatch_async(PXCLogQueue, ^{
        if (PXCLogLines >= 3000) return;
        NSString *path = PXCLogPath();
        NSString *dir = path.stringByDeletingLastPathComponent;
        NSError *e = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&e];
        if (e) return;
        int fd = open(path.fileSystemRepresentation, O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK, 0600);
        if (fd < 0) return;
        struct stat st;
        if (fstat(fd,&st) != 0 || !S_ISREG(st.st_mode) || st.st_nlink != 1 || st.st_uid != getuid()) { close(fd); return; }
        if (st.st_size > 256*1024 && ftruncate(fd,0) != 0) { close(fd); return; }
        NSString *text = [NSString stringWithFormat:@"%.3f %@\n", [NSDate date].timeIntervalSince1970, line];
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length <= 4096) { ssize_t unused = write(fd,data.bytes,data.length); (void)unused; PXCLogLines++; }
        close(fd);
    });
}
static void PXCChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    BOOL locked = name && CFEqual(name,CFSTR("com.apple.springboard.lockcomplete"));
    dispatch_async(dispatch_get_main_queue(), ^{
        if (locked) PXCRemoveAllEffects(); else PXCReload();
    });
}
void PXCSettingsStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        PXCLogQueue = dispatch_queue_create("com.niubiprass.particlex.log", DISPATCH_QUEUE_SERIAL);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PXCChanged, PXC_CHANGED_CF, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PXCChanged, CFSTR("com.apple.springboard.lockcomplete"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { PXCRemoveAllEffects(); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { PXCReload(); }];
        PXCReload();
    });
}

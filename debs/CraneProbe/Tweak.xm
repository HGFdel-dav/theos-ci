// 一次性动作：用 Crane 重置闪连容器（触发文件存在才执行）
#import <substrate.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#define LOGPATH @"/var/mobile/Containers/Shared/AppGroup/FE3195E7-59B2-4284-BCCD-C16BE374F8BF/Library/Preferences/crane-probe.log"
#define TRIGGER @"/var/mobile/Containers/Shared/AppGroup/FE3195E7-59B2-4284-BCCD-C16BE374F8BF/Library/Preferences/crane-do-wipe"
#define BUNDLE  @"com.shanlian.pro"
#define CONT    @"DEFAULT"

static void PL(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%.0f %@\n", [NSDate date].timeIntervalSince1970, s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LOGPATH];
    if (!fh) [line writeToFile:LOGPATH atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    else { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}

static void DoWipe(void) {
    Class mgr = NSClassFromString(@"CraneManager");
    if (!mgr) { PL(@"WIPE abort: no CraneManager"); return; }
    id inst = ((id (*)(id, SEL))objc_msgSend)(mgr, sel_registerName("sharedManager"));
    if (!inst) { PL(@"WIPE abort: no manager"); return; }

    SEL w = sel_registerName("wipeContainerWithIdentifier:forApplicationWithIdentifier:shouldRepopulate:");
    if (![inst respondsToSelector:w]) { PL(@"WIPE abort: no selector"); return; }

    PL(@"WIPE start bundle=%@ container=%@", BUNDLE, CONT);
    ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(inst, w, CONT, BUNDLE, YES);
    PL(@"WIPE issued");

    // 回读核对
    SEL s1 = sel_registerName("containerIdentifiersOfApplicationWithIdentifier:");
    if ([inst respondsToSelector:s1]) {
        id r = ((id (*)(id, SEL, id))objc_msgSend)(inst, s1, BUNDLE);
        PL(@"after containers=%@", r);
    }
    SEL s3 = sel_registerName("deviceIdentifierToUseForContainerWithIdentifier:ofApplicationWithIdentifier:");
    if ([inst respondsToSelector:s3]) {
        id r = ((id (*)(id, SEL, id, id))objc_msgSend)(inst, s3, CONT, BUNDLE);
        PL(@"after deviceId=%@", r);
    }
    PL(@"WIPE done");
}

__attribute__((constructor)) static void Init(void) {
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (![[NSFileManager defaultManager] fileExistsAtPath:TRIGGER]) return;
        [[NSFileManager defaultManager] removeItemAtPath:TRIGGER error:NULL];
        PL(@"trigger consumed");
        DoWipe();
    });
}

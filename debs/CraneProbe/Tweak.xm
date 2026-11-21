// Crane 重置能力探针：只查看，不执行重置
#import <substrate.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#define LOGPATH @"/var/mobile/Containers/Shared/AppGroup/FE3195E7-59B2-4284-BCCD-C16BE374F8BF/Library/Preferences/crane-probe.log"

static void PL(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                    dateStyle:NSDateFormatterNoStyle
                                                    timeStyle:NSDateFormatterMediumStyle], s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LOGPATH];
    if (!fh) { [line writeToFile:LOGPATH atomically:YES encoding:NSUTF8StringEncoding error:NULL]; }
    else { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}

static void ProbeCrane(void) {
    PL(@"=== crane probe start ===");
    Class mgr = NSClassFromString(@"CraneManager");
    PL(@"CraneManager=%p", mgr);
    if (!mgr) { PL(@"CraneManager 未加载"); return; }

    // 列出所有类方法
    unsigned int n = 0;
    Method *cms = class_copyMethodList(object_getClass(mgr), &n);
    PL(@"class methods=%u", n);
    for (unsigned int i = 0; i < n; i++) {
        const char *nm = sel_getName(method_getName(cms[i]));
        if (strstr(nm, "wipe") || strstr(nm, "delete") || strstr(nm, "deviceIdentifier") ||
            strstr(nm, "container") || strstr(nm, "Container") || strstr(nm, "manager") ||
            strstr(nm, "shared") || strstr(nm, "default")) {
            PL(@"  + %s  type=%s", nm, method_getTypeEncoding(cms[i]));
        }
    }
    free(cms);

    // 列出所有实例方法
    Method *ims = class_copyMethodList(mgr, &n);
    PL(@"instance methods=%u", n);
    for (unsigned int i = 0; i < n; i++) {
        const char *nm = sel_getName(method_getName(ims[i]));
        if (strstr(nm, "wipe") || strstr(nm, "deleteContent") || strstr(nm, "deleteKeychain") ||
            strstr(nm, "deviceIdentifier") || strstr(nm, "activeContainer") ||
            strstr(nm, "containerIdentifiers") || strstr(nm, "createNew") ||
            strstr(nm, "isApplicationSupported")) {
            PL(@"  - %s  type=%s", nm, method_getTypeEncoding(ims[i]));
        }
    }
    free(ims);

    // 尝试取 manager 实例
    id inst = nil;
    for (NSString *sn in @[@"sharedManager", @"defaultManager", @"sharedInstance", @"manager"]) {
        SEL s = NSSelectorFromString(sn);
        if ([mgr respondsToSelector:s]) {
            inst = ((id (*)(id, SEL))objc_msgSend)(mgr, s);
            PL(@"manager via +%@ -> %p", sn, inst);
            break;
        }
    }
    if (!inst) { PL(@"拿不到 manager 实例"); return; }

    // 只读查询：闪连的容器列表和当前容器
    SEL s1 = NSSelectorFromString(@"containerIdentifiersOfApplicationWithIdentifier:");
    if ([inst respondsToSelector:s1]) {
        id r = ((id (*)(id, SEL, id))objc_msgSend)(inst, s1, @"com.shanlian.pro");
        PL(@"containers=%@", r);
    } else PL(@"没有 containerIdentifiersOfApplicationWithIdentifier:");

    SEL s2 = NSSelectorFromString(@"activeContainerIdentifierForApplicationWithIdentifier:");
    if ([inst respondsToSelector:s2]) {
        id r = ((id (*)(id, SEL, id))objc_msgSend)(inst, s2, @"com.shanlian.pro");
        PL(@"activeContainer=%@", r);
    } else PL(@"没有 activeContainerIdentifierForApplicationWithIdentifier:");

    SEL s3 = NSSelectorFromString(@"deviceIdentifierToUseForContainerWithIdentifier:ofApplicationWithIdentifier:");
    if ([inst respondsToSelector:s3]) {
        id r = ((id (*)(id, SEL, id, id))objc_msgSend)(inst, s3, @"DEFAULT", @"com.shanlian.pro");
        PL(@"deviceIdentifier(DEFAULT)=%@", r);
    } else PL(@"没有 deviceIdentifierToUseForContainer...");

    PL(@"=== crane probe end ===");
}

__attribute__((constructor)) static void ProbeInit(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    if (![bid isEqualToString:@"com.apple.springboard"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ProbeCrane(); });
}

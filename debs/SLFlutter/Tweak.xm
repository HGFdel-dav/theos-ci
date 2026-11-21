// 在扩展进程里无界面启动 Flutter 引擎，让 App 的 Dart 代码跑起来
#import <substrate.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <sys/socket.h>

#define GDIR @"/var/mobile/Containers/Shared/AppGroup/FE3195E7-59B2-4284-BCCD-C16BE374F8BF/Library/Preferences"
#define LGFILE GDIR "/sl-flutter.log"

static void LGF(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%.0f %@\n", [NSDate date].timeIntervalSince1970, s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LGFILE];
    if (!fh) [line writeToFile:LGFILE atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    else { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}

// 记录网络写，判断 Dart 是否真的在发请求
static ssize_t (*origWrite)(int, const void *, size_t);
static ssize_t myWrite(int fd, const void *buf, size_t len) {
    if (buf && len > 200) {
        const char *p = (const char *)buf;
        if (memmem(p, len, "slfirstDeviceLoginfn", 20) || memmem(p, len, "/app/tourist/", 13)) {
            LGF(@"NET write len=%zu hit app-api", len);
        }
    }
    return origWrite ? origWrite(fd, buf, len) : -1;
}

__attribute__((constructor)) static void Init(void) {
    if (![[NSBundle mainBundle].bundleIdentifier hasPrefix:@"com.shanlian.pro"]) return;
    LGF(@"=== headless start ===");

    NSString *base = @"/var/containers/Bundle/Application/B50A8D68-54AA-47F7-9273-F3EB11B692B1/Runner.app";
    void *h = dlopen([base stringByAppendingPathComponent:@"Frameworks/Flutter.framework/Flutter"].UTF8String,
                     RTLD_LAZY | RTLD_GLOBAL);
    if (!h) { LGF(@"dlopen fail %s", dlerror()); return; }
    MSHookFunction((void *)write, (void *)myWrite, (void **)&origWrite);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            Class projC = NSClassFromString(@"FlutterDartProject");
            Class engC  = NSClassFromString(@"FlutterEngine");
            NSBundle *appBundle = [NSBundle bundleWithPath:base];
            LGF(@"appBundle=%@", appBundle.bundlePath);

            id proj = ((id (*)(id, SEL))objc_msgSend)(projC, sel_registerName("alloc"));
            SEL ipdb = sel_registerName("initWithPrecompiledDartBundle:");
            if ([proj respondsToSelector:ipdb]) {
                proj = ((id (*)(id, SEL, id))objc_msgSend)(proj, ipdb, appBundle);
                LGF(@"project initWithPrecompiledDartBundle -> %p", proj);
            } else {
                proj = ((id (*)(id, SEL))objc_msgSend)(proj, sel_registerName("init"));
                LGF(@"project init -> %p", proj);
            }
            if (!proj) { LGF(@"project nil"); return; }

            id eng = ((id (*)(id, SEL))objc_msgSend)(engC, sel_registerName("alloc"));
            SEL iep = sel_registerName("initWithName:project:");
            eng = ((id (*)(id, SEL, id, id))objc_msgSend)(eng, iep, @"slheadless", proj);
            LGF(@"engine=%p", eng);
            if (!eng) return;

            SEL runSel = sel_registerName("run");
            BOOL ok = ((BOOL (*)(id, SEL))objc_msgSend)(eng, runSel);
            LGF(@"engine run -> %d", ok);

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                LGF(@"=== 12s later, still alive ===");
                SEL ir = sel_registerName("isRunning");
                if ([eng respondsToSelector:ir])
                    LGF(@"engine isRunning=%d", ((BOOL (*)(id, SEL))objc_msgSend)(eng, ir));
            });
        } @catch (NSException *e) {
            LGF(@"exception %@: %@", e.name, e.reason ?: @"-");
        }
    });
}

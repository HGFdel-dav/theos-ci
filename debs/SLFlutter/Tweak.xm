// 在 VPN 扩展进程里验证：能否加载 Flutter 引擎
#import <substrate.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

#define GDIR @"/var/mobile/Containers/Shared/AppGroup/FE3195E7-59B2-4284-BCCD-C16BE374F8BF/Library/Preferences"
#define LGFILE GDIR "/sl-flutter.log"

static void LGF(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%.0f %@\n", [NSDate date].timeIntervalSince1970, s];
    NSString *path = LGFILE;
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    else { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}

__attribute__((constructor)) static void Init(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    if (![bid hasPrefix:@"com.shanlian.pro"]) return;
    LGF(@"=== probe in %@ ===", bid);

    NSString *base = @"/var/containers/Bundle/Application/B50A8D68-54AA-47F7-9273-F3EB11B692B1/Runner.app";
    NSString *fl = [base stringByAppendingPathComponent:@"Frameworks/Flutter.framework/Flutter"];
    LGF(@"exists Flutter=%d", [[NSFileManager defaultManager] fileExistsAtPath:fl]);

    void *h = dlopen(fl.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    LGF(@"dlopen Flutter = %p err=%s", h, dlerror() ?: "-");
    if (!h) return;

    Class proj = NSClassFromString(@"FlutterDartProject");
    Class eng  = NSClassFromString(@"FlutterEngine");
    Class vc   = NSClassFromString(@"FlutterViewController");
    LGF(@"classes: project=%p engine=%p vc=%p", proj, eng, vc);

    // 只检查能否用 App.framework 里的 Dart 代码建 project（不 run）
    NSString *appFw = [base stringByAppendingPathComponent:@"Frameworks/App.framework/App"];
    LGF(@"App snapshot exists=%d size=%lld",
        [[NSFileManager defaultManager] fileExistsAtPath:appFw],
        (long long)[[NSFileManager defaultManager] attributesOfItemAtPath:appFw error:NULL].fileSize);

    if (proj) {
        @try {
            id p = ((id (*)(id, SEL))objc_msgSend)(proj, sel_registerName("alloc"));
            LGF(@"project alloc = %p", p);
        } @catch (NSException *e) {
            LGF(@"project exception %@", e.reason ?: @"-");
        }
    }
    LGF(@"=== probe end ===");
}

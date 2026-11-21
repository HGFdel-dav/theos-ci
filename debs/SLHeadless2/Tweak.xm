// 注入到 cranehelperd（arm64 常驻守护进程）：无界面运行闪连的 Dart 代码
#import <substrate.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define GDIR @"/var/mobile/Containers/Shared/AppGroup/FE3195E7-59B2-4284-BCCD-C16BE374F8BF/Library/Preferences"
#define LGFILE GDIR "/sl-headless.log"
#define APP @"/var/containers/Bundle/Application/B50A8D68-54AA-47F7-9273-F3EB11B692B1/Runner.app"

static void LG(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%.0f %@\n", [NSDate date].timeIntervalSince1970, s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LGFILE];
    if (!fh) [line writeToFile:LGFILE atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    else { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    fflush(stdout);
}

static id g_engine = nil;

static void StartEngine(void) {
    LG(@"--- step1 dlopen Flutter");
    NSString *fl = [APP stringByAppendingPathComponent:@"Frameworks/Flutter.framework/Flutter"];
    void *h = dlopen(fl.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    LG(@"step1 done h=%p err=%s", h, dlerror() ?: "-");
    if (!h) return;

    Class projC = NSClassFromString(@"FlutterDartProject");
    Class engC  = NSClassFromString(@"FlutterEngine");
    LG(@"step2 classes proj=%p eng=%p", projC, engC);
    if (!projC || !engC) return;

    NSBundle *appBundle = [NSBundle bundleWithPath:APP];
    LG(@"step3 appBundle=%@", appBundle ? appBundle.bundlePath : @"nil");

    id proj = ((id (*)(id, SEL))objc_msgSend)(projC, sel_registerName("alloc"));
    SEL ipdb = sel_registerName("initWithPrecompiledDartBundle:");
    if ([proj respondsToSelector:ipdb]) {
        proj = ((id (*)(id, SEL, id))objc_msgSend)(proj, ipdb, appBundle);
        LG(@"step4 project(precompiled)=%p", proj);
    } else {
        proj = ((id (*)(id, SEL))objc_msgSend)(proj, sel_registerName("init"));
        LG(@"step4 project(init)=%p", proj);
    }
    if (!proj) return;

    LG(@"step5 alloc engine");
    id eng = ((id (*)(id, SEL))objc_msgSend)(engC, sel_registerName("alloc"));
    LG(@"step6 init engine");
    eng = ((id (*)(id, SEL, id, id))objc_msgSend)(eng, sel_registerName("initWithName:project:"),
                                                 @"slheadless", proj);
    LG(@"step7 engine=%p", eng);
    if (!eng) return;
    g_engine = eng;

    LG(@"step8 run");
    BOOL ok = ((BOOL (*)(id, SEL))objc_msgSend)(eng, sel_registerName("run"));
    LG(@"step9 run=%d", ok);
}

__attribute__((constructor)) static void Init(void) {
    NSString *name = [NSProcessInfo processInfo].processName;
    if (![name isEqualToString:@"cranehelperd"]) return;
    LG(@"=== injected into cranehelperd ===");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try { StartEngine(); }
        @catch (NSException *e) { LG(@"EXC %@ %@", e.name, e.reason ?: @"-"); }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LG(@"=== 20s later alive=1 ===");
        });
    });
}

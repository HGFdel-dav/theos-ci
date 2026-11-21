// 独立后台程序：加载 Flutter 引擎，让闪连的 Dart 代码在无界面情况下运行
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kLog = @"/var/mobile/Containers/Shared/AppGroup/FE3195E7-59B2-4284-BCCD-C16BE374F8BF/Library/Preferences/sl-headless.log";
static NSString *const kApp  = @"/var/containers/Bundle/Application/B50A8D68-54AA-47F7-9273-F3EB11B692B1/Runner.app";

static void LG(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%.0f %@\n", [NSDate date].timeIntervalSince1970, s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLog];
    if (!fh) [line writeToFile:kLog atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    else { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    printf("%s", line.UTF8String);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        LG(@"=== headless daemon start ===");
        NSString *fl = [kApp stringByAppendingPathComponent:@"Frameworks/Flutter.framework/Flutter"];
        void *h = dlopen(fl.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
        LG(@"dlopen Flutter=%p err=%s", h, dlerror() ?: "-");
        if (!h) return 1;

        Class projC = NSClassFromString(@"FlutterDartProject");
        Class engC  = NSClassFromString(@"FlutterEngine");
        LG(@"classes proj=%p eng=%p", projC, engC);
        if (!projC || !engC) return 2;

        NSBundle *appBundle = [NSBundle bundleWithPath:kApp];
        LG(@"appBundle=%@", appBundle.bundlePath);

        id proj = ((id (*)(id, SEL))objc_msgSend)(projC, sel_registerName("alloc"));
        SEL ipdb = sel_registerName("initWithPrecompiledDartBundle:");
        if ([proj respondsToSelector:ipdb]) {
            proj = ((id (*)(id, SEL, id))objc_msgSend)(proj, ipdb, appBundle);
            LG(@"project(precompiled) -> %p", proj);
        } else {
            proj = ((id (*)(id, SEL))objc_msgSend)(proj, sel_registerName("init"));
            LG(@"project(init) -> %p", proj);
        }
        if (!proj) return 3;

        id eng = ((id (*)(id, SEL))objc_msgSend)(engC, sel_registerName("alloc"));
        eng = ((id (*)(id, SEL, id, id))objc_msgSend)(eng, sel_registerName("initWithName:project:"),
                                                     @"slheadless", proj);
        LG(@"engine=%p", eng);
        if (!eng) return 4;

        BOOL ok = ((BOOL (*)(id, SEL))objc_msgSend)(eng, sel_registerName("run"));
        LG(@"engine run -> %d", ok);

        // 保持运行，让 Dart 有时间跑
        for (int i = 0; i < 12; i++) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:5]];
            SEL ir = sel_registerName("isRunning");
            BOOL r = [eng respondsToSelector:ir] ? ((BOOL (*)(id, SEL))objc_msgSend)(eng, ir) : NO;
            LG(@"tick %d engine isRunning=%d", i, r);
        }
        LG(@"=== daemon end ===");
    }
    return 0;
}

// 在扩展进程里加载闪连主程序，列出它的类和方法（只读）
#import <substrate.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

#define GDIR @"/var/mobile/Containers/Shared/AppGroup/FE3195E7-59B2-4284-BCCD-C16BE374F8BF/Library/Preferences"
#define LGFILE GDIR "/sl-dump.log"
#define APP @"/var/containers/Bundle/Application/B50A8D68-54AA-47F7-9273-F3EB11B692B1/Runner.app"

static void LG(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@\n", s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LGFILE];
    if (!fh) [line writeToFile:LGFILE atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    else { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}

__attribute__((constructor)) static void Init(void) {
    if (![[NSBundle mainBundle].bundleIdentifier hasPrefix:@"com.shanlian.pro"]) return;
    LG(@"=== dump start ===");
    NSString *runner = [APP stringByAppendingPathComponent:@"Runner"];
    void *h = dlopen(runner.UTF8String, RTLD_LAZY);
    LG(@"dlopen Runner = %p err=%s", h, dlerror() ?: "-");
    if (!h) return;

    int total = 0;
    int shown = 0;
    int n = objc_getClassList(NULL, 0);
    LG(@"total classes in image: %d", n);
    if (n > 0) {
        Class *list = (Class *)malloc(sizeof(Class) * n);
        n = objc_getClassList(list, n);
        for (int i = 0; i < n; i++) {
            const char *cn = class_getName(list[i]);
            if (!cn) continue;
            total++;
            NSString *name = @(cn);
            BOOL interesting = [name containsString:@"Crypt"] || [name containsString:@"Encrypt"] ||
                               [name containsString:@"Device"] || [name containsString:@"Sign"] ||
                               [name containsString:@"Security"] || [name containsString:@"Util"];
            if (!interesting) continue;
            LG(@"CLASS %@", name);
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(list[i], &mc);
            for (unsigned int k = 0; k < mc && k < 40; k++) {
                const char *sel = sel_getName(method_getName(ms[k]));
                if (strstr(sel, "encrypt") || strstr(sel, "Encrypt") || strstr(sel, "device") ||
                    strstr(sel, "Device") || strstr(sel, "data") || strstr(sel, "Data") ||
                    strstr(sel, "sign") || strstr(sel, "Sign")) {
                    LG(@"    - %s", sel);
                    shown++;
                }
            }
            free(ms);
        }
        free(list);
    }
    LG(@"=== dump end classes=%d hits=%d ===", total, shown);
}

// Included by CXSystemRouting.inc. Read-only diagnostics for the payment
// "split then fullscreen" report. Logs option KEY NAMES only, plus two
// non-sensitive values (ActivateSuspended, __LaunchOrigin); never URL/payload.
#import <dlfcn.h>

static NSString *CXDiagSuspendKey(void) {
    static dispatch_once_t once;
    static NSString *key = nil;
    dispatch_once(&once, ^{
        NSString * __unsafe_unretained *slot =
            (NSString * __unsafe_unretained *)dlsym(RTLD_DEFAULT, "FBSOpenApplicationOptionKeyActivateSuspended");
        if (slot && *slot) key = [*slot copy];
    });
    return key;
}

static NSDictionary *CXDiagOptions(id request) {
    id options = CXRequestObjectValue(request, @"options");
    if ([options isKindOfClass:NSDictionary.class]) return options;
    id dict = CXRequestObjectValue(options, @"dictionary");
    return [dict isKindOfClass:NSDictionary.class] ? dict : nil;
}

static void CXLogRequestOptions(NSString *bundleID, id request, const char *stage) {
    @try {
        NSDictionary *opts = CXDiagOptions(request);
        if (!opts) {
            CXLog(@"[diag] %@ %s request=%p options=<unreadable>", bundleID ?: @"?", stage, request);
            return;
        }
        NSString *suspendKey = CXDiagSuspendKey();
        // <nokey>: 常量符号没解析到，无法判断；<none>: 键存在解析但请求里没有此项。
        id suspended = suspendKey.length ? (opts[suspendKey] ?: @"<none>") : @"<nokey>";
        id origin = opts[@"__LaunchOrigin"];
        NSMutableArray<NSString *> *keys = [NSMutableArray array];
        for (id key in opts) [keys addObject:[key description] ?: @"?"];
        [keys sortUsingSelector:@selector(compare:)];
        CXLog(@"[diag] %@ %s request=%p suspend=%@ origin=%@ keys=%@", bundleID ?: @"?", stage, request,
              suspended,
              [origin isKindOfClass:NSString.class] ? origin : @"<none>",
              [keys componentsJoinedByString:@","]);
    } @catch (NSException *e) {
        CXLog(@"[diag] %@ %s exception=%@", bundleID ?: @"?", stage, e.name);
    }
}

// Which app SpringBoard considers frontmost (fullscreen) at a given moment.
static NSString *CXDiagFrontmostBundle(void) {
    UIApplication *sb = UIApplication.sharedApplication;
    SEL sel = NSSelectorFromString(@"_accessibilityFrontMostApplication");
    if (![sb respondsToSelector:sel]) return @"<unavailable>";
    id app = ((id (*)(id, SEL))objc_msgSend)(sb, sel);
    id bundle = CXRequestObjectValue(app, @"bundleIdentifier");
    return [bundle isKindOfClass:NSString.class] ? bundle : @"<springboard>";
}

static void CXLogFrontmostTimeline(NSString *bundleID) {
    for (NSNumber *delay in @[@0.5, @1.5, @3.0, @5.0, @8.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                CXLog(@"[diag] %@ +%.1fs frontmost=%@", bundleID ?: @"?", delay.doubleValue,
                      CXDiagFrontmostBundle());
            } @catch (NSException *e) {
                CXLog(@"[diag] %@ frontmost exception=%@", bundleID ?: @"?", e.name);
            }
        });
    }
}

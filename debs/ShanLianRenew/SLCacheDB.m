#import "SLCacheDB.h"
#import "SLRenewPaths.h"
#import <dlfcn.h>
#import <string.h>

typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;

static NSString *g_token = nil;
static NSString *g_peach = nil;
static NSString *g_sig = nil;
static NSString *g_host = nil;

@implementation SLCacheDB

// 动态取 sqlite 符号，避免链接依赖
static void *SLSym(void *h, const char *n) { return h ? dlsym(h, n) : NULL; }

+ (NSString *)cacheDBPath {
    // App 容器 Library/Caches/<bundle-id>/Cache.db
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *base = dirs.firstObject;
    if (!base.length) return nil;
    NSString *p = [base stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"%@/Cache.db", SL_APP_ID]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) return nil;
    return p;
}

// 从 request_object(NSKeyedArchiver plist) 里取出头部字典
static NSString *SLURLFromRequestObject(NSData *data) {
    if (!data.length) return nil;
    id obj = nil;
    @try {
        obj = [NSPropertyListSerialization propertyListWithData:data
                                                        options:NSPropertyListImmutable
                                                         format:NULL error:NULL];
    } @catch (__unused NSException *e) { obj = nil; }
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    id arr = ((NSDictionary *)obj)[@"Array"];
    if (![arr isKindOfClass:[NSArray class]]) return nil;
    for (id x in (NSArray *)arr) {
        if ([x isKindOfClass:[NSDictionary class]] && ((NSDictionary *)x)[@"_CFURLString"]) {
            return ((NSDictionary *)x)[@"_CFURLString"];
        }
    }
    return nil;
}

static NSDictionary *SLHeadersFromRequestObject(NSData *data) {
    if (!data.length) return nil;
    id obj = nil;
    @try {
        obj = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSObject class]
                                                fromData:data error:NULL];
    } @catch (__unused NSException *e) { obj = nil; }
    if (!obj) {
        @try {
            obj = [NSPropertyListSerialization propertyListWithData:data
                                                            options:NSPropertyListImmutable
                                                             format:NULL error:NULL];
        } @catch (__unused NSException *e) { obj = nil; }
    }
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    id arr = ((NSDictionary *)obj)[@"Array"];
    if (![arr isKindOfClass:[NSArray class]]) return nil;
    for (id x in (NSArray *)arr) {
        if ([x isKindOfClass:[NSDictionary class]]) {
            NSDictionary *d = (NSDictionary *)x;
            if (d[@"lightningx"] || d[@"peach"] || d[@"Authorization"]) return d;
        }
    }
    return nil;
}

+ (BOOL)refresh:(NSString *)host {
    NSString *path = [self cacheDBPath];
    if (!path.length) {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        SLLog(@"cache: db not found caches=%@", dirs.firstObject);
        return NO;
    }
    SLLog(@"cache: open %@", path);

    void *h = dlopen("/usr/lib/libsqlite3.dylib", RTLD_LAZY);
    if (!h) h = dlopen("libsqlite3.dylib", RTLD_LAZY);
    if (!h) { SLLog(@"cache: sqlite dlopen failed"); return NO; }

    int (*pOpenV2)(const char *, sqlite3 **, int, const char *) = SLSym(h, "sqlite3_open_v2");
    int (*pOpen)(const char *, sqlite3 **) = SLSym(h, "sqlite3_open");
    int (*pClose)(sqlite3 *) = SLSym(h, "sqlite3_close");
    int (*pPrep)(sqlite3 *, const char *, int, sqlite3_stmt **, const char **) = SLSym(h, "sqlite3_prepare_v2");
    int (*pStep)(sqlite3_stmt *) = SLSym(h, "sqlite3_step");
    int (*pFinal)(sqlite3_stmt *) = SLSym(h, "sqlite3_finalize");
    const unsigned char *(*pText)(sqlite3_stmt *, int) = SLSym(h, "sqlite3_column_text");
    int (*pBytes)(sqlite3_stmt *, int) = SLSym(h, "sqlite3_column_bytes");
    const void *(*pBlob)(sqlite3_stmt *, int) = SLSym(h, "sqlite3_column_blob");
    int (*pColType)(sqlite3_stmt *, int) = SLSym(h, "sqlite3_column_type");

    if (!pOpen || !pClose || !pPrep || !pStep || !pFinal || !pBlob || !pBytes) {
        SLLog(@"cache: sqlite symbols missing");
        return NO;
    }

    sqlite3 *db = NULL;
    // 只读 + 不建 journal + 不走锁，避免与 App 主进程争 WAL
    int ok = -1;
    if (pOpenV2) {
        ok = pOpenV2([path UTF8String], &db, 0x00000001 | 0x00008000, NULL); // READONLY|NOMUTEX
    } else if (pOpen) {
        ok = pOpen([path UTF8String], &db);
    }
    if (ok != 0 || !db) {
        SLLog(@"cache: open failed");
        if (db && pClose) pClose(db);
        return NO;
    }

    NSString *sql = @"SELECT request_object FROM cfurl_cache_blob_data ORDER BY entry_ID DESC LIMIT 400";
    sqlite3_stmt *st = NULL;
    if (pPrep(db, [sql UTF8String], -1, &st, NULL) != 0 || !st) {
        SLLog(@"cache: prepare failed");
        pClose(db);
        return NO;
    }

    NSString *bestToken = nil, *bestPeach = nil, *bestSig = nil;
    int rows = 0;
    while (pStep(st) == 100) {
        rows++;
        int n = pBytes(st, 0);
        const void *b = pBlob(st, 0);
        if (!b || n <= 0) continue;
        NSData *data = [NSData dataWithBytes:b length:(NSUInteger)n];
        NSDictionary *hdr = SLHeadersFromRequestObject(data);
        if (!hdr) continue;
        NSString *url = SLURLFromRequestObject(data);
        if (host.length && url.length) {
            NSString *h = [NSURL URLWithString:url].host;
            if (h.length && ![h isEqualToString:host]) continue;
        }

        NSString *tk = hdr[@"Authorization"];
        NSString *pe = hdr[@"peach"];
        NSString *sg = hdr[@"lightningx"];
        if (![pe isKindOfClass:[NSString class]] || ![sg isKindOfClass:[NSString class]]) continue;

        // 只取 JWT 作为 token（跳过被当成 Authorization 的设备号）
        BOOL jwt = [tk isKindOfClass:[NSString class]] && [tk hasPrefix:@"eyJ"];
        if (jwt && !bestToken) bestToken = tk;
        if (!bestSig && host.length) {
            // 无法从 cache 直接得知 host，先记下首个可用组合，实际由 SLHttp 校验
            bestPeach = pe;
            bestSig = sg;
        }
        if (bestToken && bestSig) break;
    }
    pFinal(st);
    pClose(db);

    if (bestToken) g_token = bestToken;
    if (bestSig) { g_peach = bestPeach; g_sig = bestSig; }
    SLLog(@"cache rows=%d token=%d sig=%d peach=%@", rows, bestToken ? 1 : 0, bestSig ? 1 : 0, bestPeach ?: @"-");
    return bestToken != nil || bestSig != nil;
}

+ (NSString *)token { return g_token; }
+ (NSString *)peach { return g_peach; }
+ (NSString *)signature { return g_sig; }

@end

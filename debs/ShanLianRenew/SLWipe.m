#import "SLHttp.h"
#import "SLCacheDB.h"
#import "SLRenewPaths.h"
#import <Security/Security.h>

// 钥匙串备份 + 账号清除：换号时必须让 App 忘记旧账号，它才会用新设备号重新注册
@implementation SLHttp (Wipe)

static NSString *SLKcClassOf(id c) {
    if ([(__bridge id)c isEqual:(__bridge id)kSecClassGenericPassword]) return @"genp";
    if ([(__bridge id)c isEqual:(__bridge id)kSecClassInternetPassword]) return @"inet";
    if ([(__bridge id)c isEqual:(__bridge id)kSecClassKey]) return @"key";
    if ([(__bridge id)c isEqual:(__bridge id)kSecClassCertificate]) return @"cert";
    return @"?";
}

// 把当前所有钥匙串项完整写到文件，返回路径
+ (NSString *)backupKeychain {
    NSMutableString *out = [NSMutableString string];
    NSArray *items = [self keychainItems];
    [out appendFormat:@"# count=%lu\n", (unsigned long)items.count];
    for (NSDictionary *d in items) {
        id cls = d[(__bridge id)kSecClass];
        NSString *acc = [d[(__bridge id)kSecAttrAccount] description] ?: @"";
        NSString *svc = [d[(__bridge id)kSecAttrService] description] ?: @"";
        NSString *grp = [d[(__bridge id)kSecAttrAccessGroup] description] ?: @"";
        NSData *val = d[(__bridge id)kSecValueData];
        NSString *b64 = [val isKindOfClass:[NSData class]]
            ? [val base64EncodedStringWithOptions:0] : @"";
        [out appendFormat:@"%@\t%@\t%@\t%@\t%@\n",
            SLKcClassOf(cls), acc, svc, grp, b64];
    }
    NSString *dir = [SLStateDir() stringByAppendingPathComponent:@"kc"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *p = [dir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"kc-%.0f.tsv", [NSDate date].timeIntervalSince1970]];
    [out writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    SLLog(@"kc backup %lu items -> %@", (unsigned long)items.count, p.lastPathComponent);
    return p;
}

static id SLSecClassFrom(NSString *s) {
    if ([s isEqualToString:@"genp"]) return (__bridge id)kSecClassGenericPassword;
    if ([s isEqualToString:@"inet"]) return (__bridge id)kSecClassInternetPassword;
    if ([s isEqualToString:@"key"]) return (__bridge id)kSecClassKey;
    return nil;
}

// 删除账号相关项（account 含 com.shanlian.pro），保留设备号
+ (int)wipeAccountItems {
    int n = 0;
    for (NSDictionary *d in [self keychainItems]) {
        id cls = d[(__bridge id)kSecClass];
        NSString *acc = [d[(__bridge id)kSecAttrAccount] description] ?: @"";
        NSString *svc = [d[(__bridge id)kSecAttrService] description] ?: @"";
        if ([acc isEqualToString:SL_DEVICE_KEY]) continue;
        BOOL hit = [acc containsString:@"com.shanlian.pro"] ||
                   [svc containsString:@"com.shanlian.pro"];
        if (!hit) continue;
        NSMutableDictionary *q = [@{ (__bridge id)kSecClass: cls } mutableCopy];
        if (acc.length) q[(__bridge id)kSecAttrAccount] = acc;
        if (svc.length) q[(__bridge id)kSecAttrService] = svc;
        OSStatus st = SecItemDelete((__bridge CFDictionaryRef)q);
        SLLog(@"kc del %@ acc=%@ st=%d", SLKcClassOf(cls), acc, (int)st);
        if (st == errSecSuccess) n++;
    }
    SLLog(@"kc wiped=%d", n);
    return n;
}

// 从备份文件恢复（失败回滚用）
+ (int)restoreKeychain:(NSString *)path {
    NSString *txt = [NSString stringWithContentsOfFile:path
                                              encoding:NSUTF8StringEncoding error:NULL];
    if (!txt.length) { SLLog(@"kc restore: no backup"); return 0; }
    int n = 0;
    for (NSString *line in [txt componentsSeparatedByString:@"\n"]) {
        if (!line.length || [line hasPrefix:@"#"]) continue;
        NSArray *f = [line componentsSeparatedByString:@"\t"];
        if (f.count < 5) continue;
        id cls = SLSecClassFrom(f[0]);
        if (!cls) continue;
        NSString *acc = f[1], *svc = f[2], *grp = f[3], *b64 = f[4];
        if ([acc isEqualToString:SL_DEVICE_KEY]) continue;
        NSMutableDictionary *q = [@{ (__bridge id)kSecClass: cls } mutableCopy];
        if (acc.length) q[(__bridge id)kSecAttrAccount] = acc;
        if (svc.length) q[(__bridge id)kSecAttrService] = svc;
        if (grp.length) q[(__bridge id)kSecAttrAccessGroup] = grp;
        NSData *v = b64.length ? [[NSData alloc] initWithBase64EncodedString:b64 options:0] : nil;
        NSMutableDictionary *a = [q mutableCopy];
        if (v) a[(__bridge id)kSecValueData] = v;
        OSStatus st = SecItemUpdate((__bridge CFDictionaryRef)q, (__bridge CFDictionaryRef)a);
        if (st == errSecItemNotFound) st = SecItemAdd((__bridge CFDictionaryRef)a, NULL);
        if (st == errSecSuccess) n++;
    }
    SLLog(@"kc restored=%d", n);
    return n;
}

// 删掉 App 自己的缓存库（里面有旧 token，不清就会继续用旧号）
+ (BOOL)wipeAppCacheDB {
    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *apps = [fm contentsOfDirectoryAtPath:base error:NULL];
    for (NSString *a in apps) {
        NSString *p = [base stringByAppendingPathComponent:a];
        NSString *mp = [p stringByAppendingPathComponent:@"Library/Caches/com.shanlian.pro/Cache.db"];
        if (![fm fileExistsAtPath:mp]) continue;
        for (NSString *suffix in @[@"", @"-wal", @"-shm"]) {
            NSString *f = [mp stringByAppendingString:suffix];
            if ([fm fileExistsAtPath:f]) {
                [fm removeItemAtPath:f error:NULL];
                SLLog(@"cache rm %@", f.lastPathComponent);
            }
        }
        return YES;
    }
    return NO;
}

@end

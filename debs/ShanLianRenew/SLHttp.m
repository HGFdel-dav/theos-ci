#import "SLHttp.h"
#import <string.h>
#import "SLSigner.h"
#import "SLRenewPaths.h"
#import "SLRenewState.h"
#import <Security/Security.h>

static NSArray<NSString *> *g_hosts = nil;
static NSString *g_host = nil;

@interface SLHttp ()
+ (void)_tryCalib:(NSInteger)i key:(NSData *)key done:(void (^)(NSInteger))done;
@end

@implementation SLHttp

+ (NSArray<NSString *> *)hosts {
    if (!g_hosts) g_hosts = @[ @"api.slacover.com", @"api.slapower.com", @"api.sladoc.com",
                               @"api.slcloudstore.com", @"api.slaclouds.com", @"api.qinghuapf.cn" ];
    if (!g_host) g_host = g_hosts.firstObject;
    return g_hosts;
}

+ (void)rotateHost {
    NSArray *h = [self hosts];
    NSUInteger i = [h indexOfObject:g_host];
    g_host = h[(i + 1) % h.count];
}

#pragma mark - 钥匙串里的令牌

+ (NSArray<NSDictionary *> *)itemsClass:(id)cls group:(NSString *)group {
    NSMutableDictionary *q = [@{ (__bridge id)kSecClass: cls,
                                 (__bridge id)kSecReturnAttributes: @YES,
                                 (__bridge id)kSecReturnData: @YES,
                                 (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll } mutableCopy];
    if (group.length) q[(__bridge id)kSecAttrAccessGroup] = group;
    q[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
    CFTypeRef out = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &out) != errSecSuccess || !out) return @[];
    NSArray *a = CFBridgingRelease(out);
    return [a isKindOfClass:[NSArray class]] ? a : @[];
}

+ (NSArray<NSDictionary *> *)keychainItems {
    NSMutableArray *all = [NSMutableArray array];
    for (NSString *g in @[SL_KEYCHAIN_GROUP, @""]) {
        [all addObjectsFromArray:[self itemsClass:(__bridge id)kSecClassGenericPassword group:g]];
        [all addObjectsFromArray:[self itemsClass:(__bridge id)kSecClassInternetPassword group:g]];
        [all addObjectsFromArray:[self itemsClass:(__bridge id)kSecClassKey group:g]];
    }
    return all;
}

+ (NSString *)tokenFromItems:(NSArray *)items differentFrom:(NSString *)old {
    for (NSDictionary *d in items) {
        NSData *data = d[(__bridge id)kSecValueData];
        if (![data isKindOfClass:[NSData class]] || data.length < 20) continue;
        NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (![s hasPrefix:@"eyJ"]) continue;
        if (old.length && [s isEqualToString:old]) continue;
        return s;
    }
    return nil;
}

+ (NSString *)tokenInPrefsDifferentFrom:(NSString *)old {
    NSDictionary *p = [self groupPrefs];
    for (NSString *k in p.allKeys) {
        id v = p[k];
        if (![v isKindOfClass:[NSString class]] || ![v hasPrefix:@"eyJ"]) continue;
        if (old.length && [v isEqualToString:old]) continue;
        return v;
    }
    return nil;
}

// flutter_secure_storage 包装：{"v":"..."}，也可能有 base64
+ (NSString *)tokenFromSecureStorage {
    NSDictionary *q = @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                         (__bridge id)kSecAttrAccount: @"com.shanlian.pro",
                         (__bridge id)kSecAttrAccessGroup: SL_KEYCHAIN_GROUP,
                         (__bridge id)kSecReturnData: @YES,
                         (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne };
    CFTypeRef out = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &out) != errSecSuccess || !out) return nil;
    NSData *d = CFBridgingRelease(out);
    if (![d isKindOfClass:[NSData class]] || !d.length) return nil;

    NSData *head = [d subdataWithRange:NSMakeRange(0, MIN((NSUInteger)48, d.length))];
    SLLog(@"secure item len=%lu head64=%@", (unsigned long)d.length,
          [head base64EncodedStringWithOptions:0]);

    NSString *s = nil;
    // 1) 直接按 JSON 解（不先转字符串）
    id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if ([j isKindOfClass:[NSDictionary class]]) {
        id v = ((NSDictionary *)j)[@"v"] ?: ((NSDictionary *)j)[@"value"];
        if ([v isKindOfClass:[NSString class]]) s = v;
    }
    // 2) UTF-8 / UTF-16
    if (!s) s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:d encoding:NSUTF16LittleEndianStringEncoding];
    if (!s) s = [[NSString alloc] initWithData:d encoding:NSUTF16BigEndianStringEncoding];
    if (![s isKindOfClass:[NSString class]] || !s.length) return nil;
    if ([s hasPrefix:@"eyJ"]) return s;

    NSData *b = [[NSData alloc] initWithBase64EncodedString:s
                  options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (b.length) {
        NSString *t = [[NSString alloc] initWithData:b encoding:NSUTF8StringEncoding];
        if ([t hasPrefix:@"eyJ"]) return t;
    }
    return nil;
}

+ (NSString *)currentToken {
    NSString *t = [self tokenFromSecureStorage];
    if (!t) t = [self tokenFromItems:[self keychainItems] differentFrom:nil];
    if (!t) t = [self tokenInPrefsDifferentFrom:nil];
    if (!t) SLLog(@"no token found (all sources)");
    return t;
}
+ (NSString *)newTokenDifferentFrom:(NSString *)old {
    NSString *t = [self tokenFromSecureStorage];
    if (t && (!old.length || ![t isEqualToString:old])) return t;
    t = [self tokenFromItems:[self keychainItems] differentFrom:old];
    return t ?: [self tokenInPrefsDifferentFrom:old];
}

#pragma mark - 应用组里的值

+ (NSDictionary *)groupPrefs {
    NSString *p = SLAppGroupPrefsPath();
    if (!p.length) return @{};
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

+ (NSString *)appInstanceId {
    id v = [self groupPrefs][@"appInstanceId"];
    if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < 16; i++) [s appendFormat:@"%02X", arc4random_uniform(256)];
    return s;
}

+ (NSString *)firebaseToken {
    NSDictionary *p = [self groupPrefs];
    for (NSString *k in p.allKeys) {
        NSString *l = k.lowercaseString;
        if ([l containsString:@"firebase"] && [l containsString:@"token"]) {
            id v = p[k];
            if ([v isKindOfClass:[NSString class]] && [v length] > 20) return v;
        }
    }
    return @"0000000000000000000000000000000000000000000000000000000000000000";
}

+ (NSMutableURLRequest *)request:(NSString *)method path:(NSString *)path body:(NSDictionary *)json {
    NSString *peach = [NSString stringWithFormat:@"%.0f", [NSDate date].timeIntervalSince1970 * 1000];
    SLState *st = [SLState load];
    NSData *key = [SLSigner keychainKey];

    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[NSString stringWithFormat:@"https://%@%@", g_host, path]]];
    r.HTTPMethod = method;
    r.timeoutInterval = 20;
    [r setValue:@"Shan Lian" forHTTPHeaderField:@"User-Agent"];
    [r setValue:@"1" forHTTPHeaderField:@"shanlian"];
    [r setValue:[self firebaseToken] forHTTPHeaderField:@"firebase_pntoken"];
    [r setValue:peach forHTTPHeaderField:@"peach"];
    if (key) [r setValue:[SLSigner signPeach:peach key:key idx:st.signerIdx] forHTTPHeaderField:@"lightningx"];
    [r setValue:@"4.5.4" forHTTPHeaderField:@"version"];
    [r setValue:@"15.5" forHTTPHeaderField:@"system-version"];
    [r setValue:@"1" forHTTPHeaderField:@"platform"];
    [r setValue:@"true" forHTTPHeaderField:@"virtual_machine"];
    [r setValue:@"zh-CN" forHTTPHeaderField:@"Accept-Language"];
    [r setValue:[self appInstanceId] forHTTPHeaderField:@"appInstanceId"];
    id dev = [self groupPrefs][SL_DEVICE_KEY];
    if ([dev isKindOfClass:[NSString class]]) [r setValue:dev forHTTPHeaderField:@"deviceId"];
    NSString *token = [self currentToken];
    if (token) [r setValue:token forHTTPHeaderField:@"Authorization"];
    if (json) {
        r.HTTPBody = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
        [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    return r;
}

+ (void)send:(NSString *)method path:(NSString *)path body:(NSDictionary *)json
  completion:(void (^)(NSInteger, NSDictionary *, NSError *))done {
    [self hosts];
    SLLog(@"%@ %@ host=%@ sig=%d", method, path, g_host,
          [[SLState load] signerIdx]);
    NSMutableURLRequest *r = [self request:method path:path body:json];
    [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:
      ^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err && ![(NSHTTPURLResponse *)resp statusCode]) {
            SLLog(@"net err %@ -> rotate host", err.localizedDescription);
            [self rotateHost];
        }
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        NSDictionary *o = nil;
        if (data.length) {
            id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([j isKindOfClass:[NSDictionary class]]) o = j;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(code, o, err); });
    }] resume];
}

#pragma mark - 签名校准

+ (void)calibrateSignerCompletion:(void (^)(NSInteger))done {
    NSData *key = [SLSigner keychainKey];
    if (!key) { done(-1); return; }
    if (![self currentToken]) { done(-1); return; }
    [self _tryCalib:0 key:key done:done];
}

+ (void)_tryCalib:(NSInteger)i key:(NSData *)key done:(void (^)(NSInteger))done {
    [self hosts];
    NSArray *c = [SLSigner candidatesForPeach:@"0" key:key];
    if (i >= (NSInteger)c.count) { SLLog(@"calib all failed"); done(-1); return; }
    SLLog(@"calib try %ld", (long)i);

    NSString *peach = [NSString stringWithFormat:@"%.0f", [NSDate date].timeIntervalSince1970 * 1000];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[NSString stringWithFormat:@"https://%@%@", g_host, @"/app/customer/slgetUserInfogo"]]];
    r.timeoutInterval = 15;
    [r setValue:@"Shan Lian" forHTTPHeaderField:@"User-Agent"];
    [r setValue:peach forHTTPHeaderField:@"peach"];
    [r setValue:[SLSigner signPeach:peach key:key idx:i] forHTTPHeaderField:@"lightningx"];
    [r setValue:[self currentToken] ?: @"" forHTTPHeaderField:@"Authorization"];
    [r setValue:@"1" forHTTPHeaderField:@"platform"];
    id dev = [self groupPrefs][SL_DEVICE_KEY];
    if ([dev isKindOfClass:[NSString class]]) [r setValue:dev forHTTPHeaderField:@"deviceId"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:
      ^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSDictionary *o = nil;
        if (data.length) {
            id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([j isKindOfClass:[NSDictionary class]]) o = j;
        }
        BOOL ok = [o[@"code"] integerValue] == 200 && o[@"data"];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) done(i); else [self _tryCalib:i + 1 key:key done:done];
        });
    }] resume];
}
@end

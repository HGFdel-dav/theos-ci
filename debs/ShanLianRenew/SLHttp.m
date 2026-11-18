#import "SLHttp.h"
#import "SLCacheDB.h"
#import <mach/mach.h>
#import <mach/vm_region.h>
#import <string.h>
#import "SLSigner.h"
#import "SLRenewPaths.h"
#import "SLRenewState.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonCryptor.h>

static NSArray<NSString *> *g_hosts = nil;
static NSString *g_host = nil;

@interface SLHttp ()
+ (void)_tryCalib:(NSInteger)i key:(NSData *)key done:(void (^)(NSInteger))done;
@end

@implementation SLHttp

+ (NSArray<NSString *> *)hosts {
    if (!g_hosts) g_hosts = @[ @"api.slcloudstore.com", @"api.slacover.com", @"api.slapower.com",
                               @"api.sladoc.com", @"api.slaclouds.com", @"api.qinghuapf.cn" ];
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
    NSString *best = nil;
    int bestScore = -1;
    for (NSDictionary *d in items) {
        NSData *data = d[(__bridge id)kSecValueData];
        NSString *acc0 = [d[(__bridge id)kSecAttrAccount] description] ?: @"";
        NSString *b64s = [data isKindOfClass:[NSData class]] ? [[data base64EncodedStringWithOptions:0] substringToIndex:MIN((NSUInteger)64, [data base64EncodedStringWithOptions:0].length)] : @"";
        SLLog(@"item acct=%@ len=%lu b64head=%@", acc0, (unsigned long)([data isKindOfClass:[NSData class]] ? data.length : 0), b64s);
        if (![data isKindOfClass:[NSData class]] || data.length < 20 || data.length > 4096) continue;
        NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!s.length) continue;
        BOOL ok = YES;
        for (NSUInteger i = 0; i < s.length && ok; i++) {
            unichar c = [s characterAtIndex:i];
            ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                 c == '.' || c == '_' || c == '-';
        }
        if (!ok) continue;
        if (old.length && [s isEqualToString:old]) continue;
        NSString *acct = [d[(__bridge id)kSecAttrAccount] description] ?: @"";
        int score = 0;
        if ([s hasPrefix:@"eyJ"]) score += 100;
        if ([acct isEqualToString:@"com.shanlian.pro"]) score += 30;
        if ([acct hasPrefix:@"kShanLianDeviceIdKey"] || [acct isEqualToString:@"lightningxvpnsymkey"] ||
            [acct isEqualToString:@"_pfo"] || [acct containsString:@"FIRAPP"] ||
            [acct containsString:@"gmp.measurement"] || [acct containsString:@":ios:"]) score -= 50;
        if (s.length <= 200) SLLog(@"token cand acct=%@ len=%lu score=%d", acct, (unsigned long)s.length, score);
        if (score > bestScore) { bestScore = score; best = s; }
    }
    if (best) SLLog(@"token picked score=%d len=%lu", bestScore, (unsigned long)best.length);
    return best;
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
    if (d.length < 2000) SLLog(@"secure item b64=%@", [d base64EncodedStringWithOptions:0]);

    NSString *s = nil;
    // 0) keyed archive（bplist00）
    if (d.length > 8 && !memcmp(d.bytes, "bplist", 6)) {
        @try {
            NSSet *ok = [NSSet setWithArray:@[[NSString class], [NSDictionary class],
                                              [NSArray class], [NSData class], [NSNumber class]]];
            NSError *ue = nil;
            id o = [NSKeyedUnarchiver unarchivedObjectOfClasses:ok fromData:d error:&ue];
            if (!o && ue) SLLog(@"unarchive err %@", ue.localizedDescription);
            if ([o isKindOfClass:[NSString class]]) s = o;
            else if ([o isKindOfClass:[NSDictionary class]]) {
                id v = ((NSDictionary *)o)[@"v"] ?: ((NSDictionary *)o)[@"value"];
                if ([v isKindOfClass:[NSString class]]) s = v;
            } else if ([o isKindOfClass:[NSData class]]) {
                s = [[NSString alloc] initWithData:(NSData *)o encoding:NSUTF8StringEncoding];
            }
            SLLog(@"unarchived class=%@ len=%lu", [o class], (unsigned long)[s length]);
        } @catch (NSException *e) { SLLog(@"unarchive fail %@", e.reason); }
    }
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

+ (NSString *)deviceId {
    id v = [self groupPrefs][SL_DEVICE_KEY];
    if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    NSDictionary *q = @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                         (__bridge id)kSecAttrAccount: SL_DEVICE_KEY,
                         (__bridge id)kSecAttrService: @"flutter_secure_storage_service",
                         (__bridge id)kSecAttrAccessGroup: SL_KEYCHAIN_GROUP,
                         (__bridge id)kSecReturnData: @YES,
                         (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne };
    CFTypeRef out = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &out) == errSecSuccess && out) {
        NSData *d = CFBridgingRelease(out);
        NSString *t = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if ([t isKindOfClass:[NSString class]] && t.length) return t;
    }
    return nil;
}


#pragma mark - 入口加密包 data

+ (NSString *)makeDataForJson:(NSDictionary *)json key:(NSData *)key {
    if (!key.length) return nil;
    NSData *plain = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
    if (!plain.length) return nil;
    unsigned char iv[12];
    for (int i = 0; i < 12; i++) iv[i] = (unsigned char)arc4random();
    CCCryptorRef ref = NULL;
    if (CCCryptorCreateWithMode(kCCEncrypt, kCCModeGCM, kCCAlgorithmAES, ccNoPadding,
                                iv, key.bytes, key.length, NULL, 0, 0, 0, &ref) != kCCSuccess) return nil;
    unsigned char *ct = malloc(plain.length + 16);
    size_t ctLen = 0;
    CCCryptorGCMEncrypt(ref, plain.bytes, plain.length, ct, &ctLen);
    unsigned char tag[16];
    size_t tagLen = 16;
    CCCryptorGCMFinalize(ref, tag, &tagLen);
    CCCryptorRelease(ref);
    NSMutableData *out = [NSMutableData data];
    [out appendBytes:iv length:12];
    [out appendBytes:ct length:ctLen];
    [out appendBytes:tag length:16];
    free(ct);
    return [out base64EncodedStringWithOptions:0];
}

+ (void)mintTokenCompletion:(void (^)(NSString *, NSString *))done {
    NSString *dev = [self deviceId];
    if (!dev.length) { SLLog(@"mint: no deviceId"); done(nil, @"no deviceId"); return; }
    [self mintTry:0 dev:dev done:done];
}

+ (void)mintTry:(NSInteger)i dev:(NSString *)dev done:(void (^)(NSString *, NSString *))done {
    NSData *key = [SLSigner keychainKey];
    if (!key || i > 5) { SLLog(@"mint: give up i=%ld", (long)i); done(nil, @"exhausted"); return; }
    NSString *peach = [NSString stringWithFormat:@"%.0f", [NSDate date].timeIntervalSince1970 * 1000];
    NSDictionary *clear = @{ @"deviceInfo": @"iPhone 12", @"deviceId": dev, @"deviceType": @"1" };
    NSString *b64 = [self makeDataForJson:clear key:key];
    NSMutableDictionary *body = [clear mutableCopy];
    if (b64.length) body[@"data"] = b64;
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[NSString stringWithFormat:@"https://%@%@", g_host, @"/app/tourist/slfirstDeviceLoginfn"]]];
    r.HTTPMethod = @"POST"; r.timeoutInterval = 15;
    [r setValue:@"Shan Lian" forHTTPHeaderField:@"User-Agent"];
    [r setValue:@"1" forHTTPHeaderField:@"shanlian"];
    [r setValue:[self firebaseToken] forHTTPHeaderField:@"firebase_pntoken"];
    [r setValue:peach forHTTPHeaderField:@"peach"];
    [r setValue:[SLSigner signPeach:peach key:key idx:i] forHTTPHeaderField:@"lightningx"];
    [r setValue:@"4.5.3" forHTTPHeaderField:@"version"];
    [r setValue:@"15.5" forHTTPHeaderField:@"system-version"];
    [r setValue:@"1" forHTTPHeaderField:@"platform"];
    [r setValue:@"true" forHTTPHeaderField:@"virtual_machine"];
    [r setValue:@"zh-CN" forHTTPHeaderField:@"Accept-Language"];
    [r setValue:[self appInstanceId] forHTTPHeaderField:@"appInstanceId"];
    [r setValue:dev forHTTPHeaderField:@"deviceId"];
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    SLLog(@"mint try %ld", (long)i);
    [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:
      ^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSInteger st = [(NSHTTPURLResponse *)resp statusCode];
        NSDictionary *o = nil;
        if (d.length) { id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
            if ([j isKindOfClass:[NSDictionary class]]) o = j; }
        dispatch_async(dispatch_get_main_queue(), ^{
            SLLog(@"mint try %ld -> %ld", (long)i, (long)st);
            if (st == 200 && [o[@"token"] isKindOfClass:[NSString class]]) {
                SLState *s9 = [SLState load]; s9.signerIdx = (int)i; [s9 save];
                done(o[@"token"], @"ok");
            } else if (st == 403) {
                [self mintTry:i + 1 dev:dev done:done];
            } else {
                done(nil, [NSString stringWithFormat:@"http %ld", (long)st]);
            }
        });
    }] resume];
}

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
    [self hosts];   // 确保 g_host 已初始化（refresh 需要它）
    NSString *peach = [NSString stringWithFormat:@"%.0f", [NSDate date].timeIntervalSince1970 * 1000];
    NSString *sig = nil;
    if ([SLCacheDB refresh:g_host] || [SLCacheDB signature]) {
        NSString *cp = [SLCacheDB peach];
        NSString *cs = [SLCacheDB signature];
        if (cp.length && cs.length) { peach = cp; sig = cs; }
    }
    SLState *st = [SLState load];
    NSData *key = [SLSigner keychainKey];

    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[NSString stringWithFormat:@"https://%@%@", g_host, path]]];
    r.HTTPMethod = method;
    r.timeoutInterval = 60;
    [r setValue:@"Shan Lian" forHTTPHeaderField:@"User-Agent"];
    [r setValue:@"1" forHTTPHeaderField:@"shanlian"];
    [r setValue:[self firebaseToken] forHTTPHeaderField:@"firebase_pntoken"];
    [r setValue:peach forHTTPHeaderField:@"peach"];
    if (sig.length) {
        [r setValue:sig forHTTPHeaderField:@"lightningx"];
    } else if (key) {
        [r setValue:[SLSigner signPeach:peach key:key idx:st.signerIdx] forHTTPHeaderField:@"lightningx"];
    }
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

+ (void)probeNet {
    NSArray *tests = @[@"https://api.slacover.com/app/customer/slgetUserInfogo",
                       @"https://api.slcloudstore.com/app/customer/slgetUserInfogo",
                       @"https://www.baidu.com/"];
    for (NSString *u in tests) {
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u]];
        r.timeoutInterval = 12;
        r.HTTPMethod = @"GET";
        NSDate *t0 = [NSDate date];
        [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:
          ^(NSData *d, NSURLResponse *resp, NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                SLLog(@"probe %@ -> %ld %.2fs err=%@", [u componentsSeparatedByString:@"//"].lastObject,
                      (long)[(NSHTTPURLResponse *)resp statusCode],
                      -[t0 timeIntervalSinceNow], e.localizedDescription ?: @"-");
            });
        }] resume];
    }
}

+ (void)send:(NSString *)method path:(NSString *)path body:(NSDictionary *)json
  completion:(void (^)(NSInteger, NSDictionary *, NSError *))done {
    [self hosts];
    SLLog(@"%@ %@ host=%@ sig=%d", method, path, g_host,
          [[SLState load] signerIdx]);
    NSMutableURLRequest *r = [self request:method path:path body:json];
    SLLog(@"send URL=%@ peach=%@ sig=%@ authlen=%lu",
          r.URL.absoluteString, [r valueForHTTPHeaderField:@"peach"],
          [[r valueForHTTPHeaderField:@"lightningx"] substringToIndex:MIN((NSUInteger)12, [[r valueForHTTPHeaderField:@"lightningx"] length])],
          (unsigned long)[[r valueForHTTPHeaderField:@"Authorization"] length]);
    [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:
      ^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err && ![(NSHTTPURLResponse *)resp statusCode]) {
            SLLog(@"net err %@ (host kept)", err.localizedDescription);
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

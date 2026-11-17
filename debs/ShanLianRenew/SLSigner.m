#import "SLSigner.h"
#import "SLRenewPaths.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>

@implementation SLSigner

+ (NSData *)keychainKey {
    NSDictionary *q = @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                         (__bridge id)kSecAttrAccount: @"lightningxvpnsymkey",
                         (__bridge id)kSecReturnData: @YES,
                         (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne };
    CFTypeRef out = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &out);
    if (st != errSecSuccess || !out) { SLLog(@"keychain key missing st=%d", (int)st); return nil; }
    NSData *d = CFBridgingRelease(out);
    SLLog(@"keychain key len=%lu", (unsigned long)[(NSData *)d length]);
    return [d isKindOfClass:[NSData class]] ? d : nil;
}

static NSData *HMAC256(NSData *key, NSData *msg) {
    unsigned char out[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, msg.bytes, msg.length, out);
    return [NSData dataWithBytes:out length:sizeof(out)];
}

static NSData *SHA256cat(NSData *a, NSData *b) {
    NSMutableData *m = [NSMutableData dataWithData:a];
    [m appendData:b];
    unsigned char out[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(m.bytes, (CC_LONG)m.length, out);
    return [NSData dataWithBytes:out length:sizeof(out)];
}

static NSString *B64(NSData *d) { return [d base64EncodedStringWithOptions:0]; }
static NSString *Hex(NSData *d) {
    const unsigned char *p = d.bytes; NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x", p[i]];
    return s;
}

+ (NSArray<NSString *> *)candidatesForPeach:(NSString *)peach key:(NSData *)key {
    NSData *m = [peach dataUsingEncoding:NSUTF8StringEncoding];
    return @[ B64(HMAC256(key, m)),
              Hex(HMAC256(key, m)),
              B64(SHA256cat(key, m)),
              B64(SHA256cat(m, key)),
              B64(HMAC256(key, [peach stringByAppendingString:@"\n"].length ?
                             [[peach stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding] : m)),
              B64(HMAC256([B64(key) dataUsingEncoding:NSUTF8StringEncoding], m)) ];
}

+ (NSString *)signPeach:(NSString *)peach key:(NSData *)key idx:(NSInteger)idx {
    NSArray *c = [self candidatesForPeach:peach key:key];
    if (idx < 0 || idx >= (NSInteger)c.count) return c.firstObject;
    return c[idx];
}
@end

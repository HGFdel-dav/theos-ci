#import <Foundation/Foundation.h>

@interface SLSigner : NSObject
+ (NSData *)keychainKey;                 // lightningxvpnsymkey
+ (NSArray<NSString *> *)candidatesForPeach:(NSString *)peach key:(NSData *)key;
+ (NSString *)signPeach:(NSString *)peach key:(NSData *)key idx:(NSInteger)idx;
@end

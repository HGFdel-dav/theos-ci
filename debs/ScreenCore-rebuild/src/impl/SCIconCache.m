#import <UIKit/UIKit.h>

@interface SCIconCache : NSObject
+ (instancetype)sharedCache;
- (UIImage *)iconForBundleID:(NSString *)bundleID size:(CGFloat)size;
- (void)cacheIcon:(UIImage *)icon forBundleID:(NSString *)bundleID;
- (void)clearCache;
- (NSUInteger)cacheSize;
@end

@implementation SCIconCache {
    NSMutableDictionary<NSString *, UIImage *> *_cache;
}

+ (instancetype)sharedCache {
    static SCIconCache *s = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[self alloc] init];
    });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _cache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (UIImage *)iconForBundleID:(NSString *)bundleID size:(CGFloat)size {
    NSString *key = [NSString stringWithFormat:@"%@_%.0f", bundleID, size];
    UIImage *cached = _cache[key];
    if (cached) return cached;
    
    // TODO: 从 SBApplicationController 获取真实图标
    UIImage *icon = [self generatePlaceholderIconWithSize:size];
    _cache[key] = icon;
    return icon;
}

- (UIImage *)generatePlaceholderIconWithSize:(CGFloat)size {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    [[UIColor grayColor] setFill];
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size)
                                                     cornerRadius:size * 0.2];
    [path fill];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (void)cacheIcon:(UIImage *)icon forBundleID:(NSString *)bundleID {
    _cache[bundleID] = icon;
}

- (void)clearCache {
    [_cache removeAllObjects];
}

- (NSUInteger)cacheSize {
    return _cache.count;
}

@end

#import <Foundation/Foundation.h>

@interface SCWindowMemory : NSObject
+ (instancetype)sharedMemory;
- (void)saveFrame:(CGRect)frame forBundleID:(NSString *)bundleID;
- (CGRect)frameForBundleID:(NSString *)bundleID;
- (BOOL)hasMemoryForBundleID:(NSString *)bundleID;
- (void)clearMemoryForBundleID:(NSString *)bundleID;
- (void)clearAll;
@end

@implementation SCWindowMemory {
    NSMutableDictionary<NSString *, NSValue *> *_frames;
}

+ (instancetype)sharedMemory {
    static SCWindowMemory *s = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[self alloc] init];
    });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _frames = [NSMutableDictionary dictionary];
        [self loadFromDisk];
    }
    return self;
}

- (void)loadFromDisk {
    NSString *path = [self persistencePath];
    NSDictionary *data = [NSDictionary dictionaryWithContentsOfFile:path];
    if (data) {
        [_frames addEntriesFromDictionary:data];
    }
}

- (void)saveToDisk {
    NSString *path = [self persistencePath];
    [_frames writeToFile:path atomically:YES];
}

- (NSString *)persistencePath {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [dir stringByAppendingPathComponent:@"ScreenCoreWindowMemory.plist"];
}

- (void)saveFrame:(CGRect)frame forBundleID:(NSString *)bundleID {
    _frames[bundleID] = [NSValue valueWithCGRect:frame];
    [self saveToDisk];
}

- (CGRect)frameForBundleID:(NSString *)bundleID {
    NSValue *v = _frames[bundleID];
    return v ? v.CGRectValue : CGRectZero;
}

- (BOOL)hasMemoryForBundleID:(NSString *)bundleID {
    return _frames[bundleID] != nil;
}

- (void)clearMemoryForBundleID:(NSString *)bundleID {
    [_frames removeObjectForKey:bundleID];
    [self saveToDisk];
}

- (void)clearAll {
    [_frames removeAllObjects];
    [self saveToDisk];
}

@end

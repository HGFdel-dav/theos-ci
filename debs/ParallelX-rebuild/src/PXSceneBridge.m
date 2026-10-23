#import "../headers/PXSceneBridge.h"

@implementation PXSceneBridge

+ (instancetype)sharedBridge {
    static PXSceneBridge *s = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[self alloc] init];
    });
    return s;
}

- (void)openApplication:(NSString *)bundleID 
                 inView:(UIView *)hostView 
        keyboardOverlay:(UIView *)overlay 
             completion:(void(^)(BOOL))completion {
    // TODO: 创建 scene、注入 hostView
    NSLog(@"[PX] openApplication %@ in view %@", bundleID, hostView);
    if (completion) completion(YES);
}

- (void)prepareWindowForBundleID:(NSString *)bundleID 
                  wasFullscreen:(BOOL)fullscreen 
                     completion:(void(^)(void))completion {
    // TODO: 准备窗口（clone0.24 兜底路径）
    NSLog(@"[PX] prepareWindow %@ fullscreen=%d", bundleID, fullscreen);
    if (completion) completion();
}

@end

#import "MiniSightResources.h"
#import <ImageIO/ImageIO.h>
#import <math.h>

@implementation MiniSightResources
static NSString *MSResourceContainer;
static NSString *MSAtlasIdentity;
static UIImage *MSAtlas;
static dispatch_queue_t MSResourceQueue(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.openminis.minisight.resources", DISPATCH_QUEUE_SERIAL); });
    return q;
}
static NSString *MSFindContainer(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (MSResourceContainer) {
        NSString *meta = [MSResourceContainer stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *value = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([value[@"MCMMetadataIdentifier"] isEqual:@"com.openminis.app"]) return MSResourceContainer;
    }
    MSResourceContainer = nil;
    NSString *base = @"/var/mobile/Containers/Data/Application";
    for (NSString *name in [fm contentsOfDirectoryAtPath:base error:nil]) {
        NSString *dir = [base stringByAppendingPathComponent:name];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:
            [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
        if ([meta[@"MCMMetadataIdentifier"] isEqual:@"com.openminis.app"]) { MSResourceContainer = dir; break; }
    }
    return MSResourceContainer;
}
static UIImage *MSLoadAtlas(NSString *path) {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (!attrs || ![attrs[NSFileType] isEqual:NSFileTypeRegular] ||
        [attrs[NSFileSize] unsignedLongLongValue] > 16 * 1024 * 1024) return nil;
    NSString *identity = [NSString stringWithFormat:@"%@|%@|%@", path, attrs[NSFileSize], attrs[NSFileModificationDate]];
    if ([identity isEqual:MSAtlasIdentity]) return MSAtlas;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!source) return nil;
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    double w = [props[(id)kCGImagePropertyPixelWidth] doubleValue];
    double h = [props[(id)kCGImagePropertyPixelHeight] doubleValue];
    if (w < 8. || h < 9. || w > 16384. || h > 16384. || fabs(w/h-768./936.) > .025) {
        CFRelease(source); return nil;
    }
    // The atlas never needs a Retina-sized 2304x2808 backing. Decode at most
    // 768x936 pixels once on this queue (roughly 2.75 MiB), not on a swipe frame.
    size_t targetW = (size_t)(MIN(w, 768.) / 8.) * 8;
    size_t targetH = (size_t)llround((double)targetW * 936. / 768. / 9.) * 9;
    NSDictionary *opts = @{(id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
        (id)kCGImageSourceCreateThumbnailWithTransform:@YES,
        (id)kCGImageSourceShouldCacheImmediately:@YES,
        (id)kCGImageSourceThumbnailMaxPixelSize:@(MAX(targetW, targetH))};
    CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(source);
    if (!thumb) return nil;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, targetW, targetH, 8, targetW*4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!context) { CGImageRelease(thumb); return nil; }
    CGContextDrawImage(context, CGRectMake(0, 0, targetW, targetH), thumb);
    CGImageRef decoded = CGBitmapContextCreateImage(context);
    CGContextRelease(context); CGImageRelease(thumb);
    UIImage *image = decoded ? [UIImage imageWithCGImage:decoded scale:1. orientation:UIImageOrientationUp] : nil;
    if (decoded) CGImageRelease(decoded);
    MSAtlasIdentity = identity; MSAtlas = image;
    return image;
}
+ (void)refresh:(void (^)(NSString *, NSDictionary *, BOOL, UIImage *))completion {
    dispatch_async(MSResourceQueue(), ^{
        @autoreleasepool {
            NSString *container = MSFindContainer();
            NSString *path = [container stringByAppendingPathComponent:@"Library/Preferences/com.openminis.app.plist"];
            NSDictionary *prefs = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
            if (![prefs isKindOfClass:NSDictionary.class]) prefs = @{};
            NSMutableDictionary *filtered = [NSMutableDictionary dictionary];
            for (NSString *key in prefs) {
                if ([key isKindOfClass:NSString.class] && [key hasPrefix:@"minisight."]) filtered[key] = prefs[key];
            }
            NSString *shownPath = [container stringByAppendingPathComponent:@"Documents/MiniSight/shown"];
            NSString *shown = shownPath ? [NSString stringWithContentsOfFile:shownPath encoding:NSUTF8StringEncoding error:nil] : nil;
            NSString *petPath = [container stringByAppendingPathComponent:@"Documents/MiniSight/pet.png"];
            UIImage *atlas = petPath ? MSLoadAtlas(petPath) : nil;
            NSDictionary *snapshot = [filtered copy];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(container, snapshot, ![shown isEqual:@"0"], atlas); });
        }
    });
}
+ (void)writeShown:(BOOL)shown container:(NSString *)container {
    if (!container) return;
    dispatch_async(MSResourceQueue(), ^{
        NSString *dir = [container stringByAppendingPathComponent:@"Documents/MiniSight"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *value = shown ? @"1" : @"0";
        [[value dataUsingEncoding:NSUTF8StringEncoding]
            writeToFile:[dir stringByAppendingPathComponent:@"shown"] atomically:YES];
    });
}
+ (void)releaseCachedAtlas { dispatch_async(MSResourceQueue(), ^{ MSAtlas = nil; MSAtlasIdentity = nil; }); }
@end

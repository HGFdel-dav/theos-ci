#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
// All scanning, property-list I/O and atlas decoding runs on one utility queue.
// Completion is main-thread. No renderer, gesture or display-link calls this.
@interface MiniSightResources : NSObject
+ (void)refresh:(void (^)(NSString * _Nullable container, NSDictionary *preferences,
                         BOOL shown, UIImage * _Nullable atlas))completion;
+ (void)refreshPreferences:(void (^)(NSString * _Nullable container, NSDictionary *preferences))completion;
+ (void)writeShown:(BOOL)shown container:(NSString *)container;
+ (void)releaseCachedAtlas;
@end
NS_ASSUME_NONNULL_END

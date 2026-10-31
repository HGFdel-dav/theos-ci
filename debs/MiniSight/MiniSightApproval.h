#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// One request may own the pet UI. Authority remains with the App; there is no
/// default allow and legacy text results are never generated or accepted here.
@interface MiniSightApproval : NSObject
- (instancetype)initWithContainer:(NSString *)container;
@property (nonatomic, copy, nullable) BOOL (^present)(NSString *fullText);
@property (nonatomic, copy, nullable) BOOL (^isVisible)(void);
@property (nonatomic, copy, nullable) void (^dismiss)(void);
@property (nonatomic, readonly) BOOL pending;
@property (nonatomic, readonly, nullable) NSString *requestID;
- (void)readRequest;
- (void)readPing;
- (void)readCancellation;
- (void)answer:(BOOL)allow;
/// Hide first, disable authority, then acknowledge cancellation; never approve.
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END

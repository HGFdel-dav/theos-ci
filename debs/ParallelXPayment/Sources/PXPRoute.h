#import "PXPRuntime.h"
#import "PXPState.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^PXPSystemCompletion)(NSError * _Nullable error);
@interface PXPRoute : NSObject {
@public PXPState state;
}
@property(nonatomic, copy) NSString *bundle;
@property(nonatomic, copy) NSString *container;
@property(nonatomic, strong, nullable) id receiver;
@property(nonatomic) SEL selector;
@property(nonatomic, strong, nullable) id service;
@property(nonatomic, strong, nullable) id request;
@property(nonatomic, copy, nullable) PXPSystemCompletion completion;
@property(nonatomic, copy, nullable) PXPSystemCompletion forwardedCompletion;
@property(nonatomic, strong, nullable) id transitionRequest;
@property(nonatomic, strong, nullable) id provenanceTransition;
@property(nonatomic, strong) NSHashTable *provenanceRequests;
@property(nonatomic, strong, nullable) id transitionContext;
@property(nonatomic, strong, nullable) id workspaceTransaction;
@property(nonatomic, strong, nullable) id sceneUpdateTransaction;
@property(nonatomic, strong, nullable) id sceneHandle;
@property(nonatomic, copy) NSString *sceneIdentifier;
@property(nonatomic, strong, nullable) id nativeDelegate;
@property(nonatomic, strong) NSError * _Nullable systemError;
@property(nonatomic) BOOL processVerificationStarted;
@property(nonatomic) BOOL processAccountVerified;
@property(nonatomic) BOOL systemResultReceived;
@property(nonatomic) BOOL systemCompletionDelivered;
@property(nonatomic) NSTimeInterval deadline;
- (BOOL)isCurrent;
- (void)fail:(NSError *)error;
- (void)advance;
@end
PXPRoute * _Nullable PXPAssociatedRoute(id _Nullable object);
void PXPAssociate(id _Nullable object, PXPRoute * _Nullable route);
BOOL PXPBindTransition(PXPRoute *route, id request);
PXPRoute * _Nullable PXPRouteForForwardedResult(id _Nullable workspace, id _Nullable result);
BOOL PXPHasExactProvenance(PXPRoute *route, id request);
BOOL PXPInstallProvenance(void);
void PXPClearProvenance(PXPRoute *route);
BOOL PXPInstallOwnership(void);
void PXPCallOriginalRequest(IMP original,id _Nullable receiver,SEL selector,id _Nullable service,
    id _Nullable request,PXPSystemCompletion _Nullable completion,PXPRoute * _Nullable owner);
BOOL PXPInstallNativeRouting(void);
BOOL PXPInstallHostAdapter(void);
void PXPHostScene(PXPRoute *route, void (^completion)(BOOL ready, NSError * _Nullable error));
void PXPClosePaymentHost(NSString *bundle);
void PXPCancelPaymentHost(PXPRoute *route);
BOOL PXPRoutingAvailable(void);
void PXPInstallRequestIntake(void);
void PXPTeardownNative(PXPRoute *route, void (^completion)(BOOL quiescent));

NS_ASSUME_NONNULL_END

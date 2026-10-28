#import "PXPRuntime.h"
#import "PXPState.h"

typedef void (^PXPSystemCompletion)(NSError * _Nullable error);
@interface PXPRoute : NSObject {
@public PXPState state;
}
@property(nonatomic, copy) NSString *bundle;
@property(nonatomic, copy) NSString *container;
@property(nonatomic, strong) id receiver;
@property(nonatomic) SEL selector;
@property(nonatomic, strong) id service;
@property(nonatomic, strong) id request;
@property(nonatomic, copy) PXPSystemCompletion completion;
@property(nonatomic, strong) id transitionRequest;
@property(nonatomic, strong) id provenanceTransition;
@property(nonatomic, strong) id transitionContext;
@property(nonatomic, strong) id workspaceTransaction;
@property(nonatomic, strong) id sceneUpdateTransaction;
@property(nonatomic, strong) id sceneHandle;
@property(nonatomic, copy) NSString *sceneIdentifier;
@property(nonatomic, strong) id nativeDelegate;
@property(nonatomic, strong) NSError *systemError;
@property(nonatomic) BOOL systemResultReceived;
@property(nonatomic) BOOL systemCompletionDelivered;
@property(nonatomic) NSTimeInterval deadline;
- (BOOL)isCurrent;
- (void)fail:(NSError *)error;
- (void)advance;
@end
PXPRoute *PXPAssociatedRoute(id object);
void PXPAssociate(id object, PXPRoute *route);
BOOL PXPBindTransition(PXPRoute *route, id request);
BOOL PXPHasExactProvenance(PXPRoute *route, id request);
BOOL PXPInstallProvenance(void);
void PXPClearProvenance(PXPRoute *route);
BOOL PXPInstallNativeRouting(void);
BOOL PXPInstallHostAdapter(void);
void PXPHostScene(PXPRoute *route, void (^completion)(BOOL ready, NSError *error));
void PXPClosePaymentHost(NSString *bundle);
void PXPCancelPaymentHost(PXPRoute *route);
BOOL PXPRoutingAvailable(void);
void PXPInstallRequestIntake(void);
void PXPTeardownNative(PXPRoute *route, void (^completion)(BOOL quiescent));

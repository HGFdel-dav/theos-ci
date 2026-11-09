#ifndef RD_EXTENSION_INSTALL_H
#define RD_EXTENSION_INSTALL_H
#import <objc/runtime.h>

static NSString *const kRDAddonVersion = @"1.9";
static char kRDBackendKey;
static BOOL rdInstallIssued;
static BOOL rdInstallScheduled;
static BOOL rdAddonConfirmed;
static id rdAddonBackend;

@interface RDAddonInstallReply : NSObject <RDEventCallback>
@end
static RDAddonInstallReply *rdAddonInstallReply;

static NSString *RDStageSignedExtension(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ReynardDefault-handoff.xpi"];
    NSData *signedData = [NSData dataWithBytes:kHandoffXpi length:kHandoffXpiLen];
    NSData *existing = [NSData dataWithContentsOfFile:path];
    if (![existing isEqualToData:signedData]) {
        NSError *error = nil;
        if (![signedData writeToFile:path options:NSDataWritingAtomic error:&error]) {
            RDLog(@"addon staging failed code=%ld", (long)error.code);
            return nil;
        }
    }
    if (![[NSData dataWithContentsOfFile:path] isEqualToData:signedData]) {
        RDLog(@"addon staging readback mismatch"); return nil;
    }
    return [NSURL fileURLWithPath:path].absoluteString;
}
static void RDRememberAttachedBackend(id wrapper, id backend) {
    // attach: is an actual ObjC entry point in the installed framework.
    // Do not read Swift existential storage with object_getIvar or KVC.
    if (backend && ![backend respondsToSelector:@selector(dispatchToGecko:message:callback:)]) return;
    objc_setAssociatedObject(wrapper, &kRDBackendKey, backend, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL RDIsOurExtension(NSDictionary *extension) {
    return [extension isKindOfClass:[NSDictionary class]] &&
           [extension[@"webExtensionId"] isKindOfClass:[NSString class]] &&
           [extension[@"webExtensionId"] isEqualToString:kHandoffAddonID];
}
static BOOL RDInstalledPayloadReady(id response) {
    if (![response isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *extension = response[@"extension"];
    if (!RDIsOurExtension(extension)) return NO;
    NSDictionary *metadata = extension[@"metaData"];
    if (![metadata isKindOfClass:[NSDictionary class]]) return NO;
    return [metadata[@"version"] isKindOfClass:[NSString class]] &&
           [metadata[@"version"] isEqualToString:kRDAddonVersion] &&
           [metadata[@"enabled"] isKindOfClass:[NSNumber class]] && [metadata[@"enabled"] boolValue];
}
@implementation RDAddonInstallReply
- (void)sendSuccess:(id)response {
    dispatch_async(dispatch_get_main_queue(), ^{
        rdAddonConfirmed = RDInstalledPayloadReady(response);
        RDLog(@"addon version=%@ verified=%d", kRDAddonVersion, rdAddonConfirmed);
        // No automatic reload and no synthetic navigation. Content scripts take
        // effect on documents created after the signed extension is enabled.
    });
}
- (void)sendError:(id)response {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNumber *code = [response isKindOfClass:[NSDictionary class]] ? response[@"installError"] : nil;
        RDLog(@"addon install failed code=%@", code ?: @"unknown");
    });
}
@end

static void RDObserveRuntimeExtension(id wrapper, NSString *type, id message) {
    // Runtime-only notifications, not session Connect/Message/PortMessage.
    BOOL runtime = [type isEqualToString:@"GeckoView:WebExtension:OnReady"] ||
                   [type isEqualToString:@"GeckoView:WebExtension:OnInstalled"];
    if (!runtime || ![message isKindOfClass:[NSDictionary class]]) return;
    if (RDInstalledPayloadReady(message)) {
        rdAddonConfirmed = YES;
        RDLog(@"addon ready version=%@", kRDAddonVersion);
        return;
    }
    if (rdInstallIssued || rdInstallScheduled || rdAddonConfirmed) return;
    id backend = objc_getAssociatedObject(wrapper, &kRDBackendKey);
    if (![backend respondsToSelector:@selector(dispatchToGecko:message:callback:)]) {
        RDLog(@"addon awaiting attached runtime backend"); return;
    }
    rdAddonBackend = backend;
    rdInstallScheduled = YES;
    // Give the runtime its startup ready events before deciding an upgrade is
    // needed. Existing current-version installations are left alone.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        rdInstallScheduled = NO;
        if (rdAddonConfirmed || !rdAddonBackend || rdInstallIssued) return;
        Protocol *protocol = objc_getProtocol("EventCallback");
        if (!protocol) { RDLog(@"addon EventCallback unavailable"); return; }
        Class cls = [RDAddonInstallReply class];
        if (!class_conformsToProtocol(cls, protocol)) class_addProtocol(cls, protocol);
        if (!class_conformsToProtocol(cls, protocol)) { RDLog(@"addon callback ABI unavailable"); return; }
        NSString *location = RDStageSignedExtension();
        if (!location) return;
        rdAddonInstallReply = [RDAddonInstallReply new];
        rdInstallIssued = YES;
        [(id<RDGeckoDispatch>)rdAddonBackend dispatchToGecko:@"GeckoView:WebExtension:Install"
          message:@{@"locationUri": location, @"installMethod": @"manager",
                    @"installId": [NSString stringWithFormat:@"reynarddefault-%@", [NSUUID UUID].UUIDString]}
          callback:rdAddonInstallReply];
        RDLog(@"addon install requested version=%@", kRDAddonVersion);
    });
}
#endif

#import "MiniSightApproval.h"
#import "MiniSightBridgeIO.h"
#import <signal.h>
#import <limits.h>

static BOOL MSApprovalUUID(id value) {
    return [value isKindOfClass:NSString.class] && [value length] == 36 &&
        [[NSUUID alloc] initWithUUIDString:value] != nil;
}
static BOOL MSApprovalVersion(NSDictionary *value) {
    id version = value[@"protocolVersion"];
    return [version isKindOfClass:NSNumber.class] && [version integerValue] == 2;
}
static BOOL MSApprovalAlive(NSDictionary *request) {
    id pid = request[@"pid"];
    if (![pid isKindOfClass:NSNumber.class]) return NO;
    double number = [pid doubleValue];
    if (number < 2. || number > INT_MAX || floor(number) != number) return NO;
    return kill((pid_t)number, 0) == 0 || errno == EPERM;
}
static BOOL MSApprovalRevoked(NSString *container, NSDictionary *request) {
    NSDictionary *cancel = MSBridgeRead(container, @"confirm-cancel.json", 4096);
    return MSApprovalVersion(cancel) && [cancel[@"id"] isEqual:request[@"id"]];
}
static BOOL MSApprovalRequestValid(NSString *container, NSDictionary *request) {
    if (!MSApprovalVersion(request) || !MSApprovalUUID(request[@"id"]) ||
        !MSApprovalUUID(request[@"challenge"]) || !MSApprovalUUID(request[@"processInstanceID"]) ||
        !MSApprovalAlive(request) || MSApprovalRevoked(container, request)) return NO;
    for (NSString *field in @[@"action", @"purpose", @"risk", @"command"]) {
        if (![request[field] isKindOfClass:NSString.class]) return NO;
    }
    if ([request[@"command"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 65536) return NO;
    // A recycled/stale request cannot borrow another process's visible pet.
    NSDictionary *activity = MSBridgeRead(container, @"activity.json", 16384);
    return [activity[@"protocolVersion"] integerValue] == 1 &&
        [activity[@"pid"] isEqual:request[@"pid"]] &&
        [activity[@"processInstanceID"] isEqual:request[@"processInstanceID"]] &&
        [activity[@"pendingApprovalCount"] integerValue] > 0;
}
static NSString *MSApprovalText(NSDictionary *request) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ([request[@"action"] length]) [parts addObject:request[@"action"]];
    if ([request[@"purpose"] length]) [parts addObject:[@"用途：" stringByAppendingString:request[@"purpose"]]];
    if ([request[@"risk"] length]) [parts addObject:[@"风险：" stringByAppendingString:request[@"risk"]]];
    // FULL authorization text. No truncation, logging, AI or status propagation.
    if ([request[@"command"] length]) [parts addObject:request[@"command"]];
    return [parts componentsJoinedByString:@"\n\n"];
}

@interface MiniSightApproval ()
@property (nonatomic, copy) NSString *container;
@property (nonatomic, strong) NSDictionary *request;
@property (nonatomic, copy) NSString *challenge;
@property (nonatomic, strong) NSMutableArray<NSString *> *endedIDs;
@property (nonatomic) BOOL presented;
@property (nonatomic) BOOL settling;
@property (nonatomic) NSUInteger epoch;
@property (nonatomic) NSUInteger readGeneration;
@end

@implementation MiniSightApproval {
    dispatch_queue_t _io;
}
- (instancetype)initWithContainer:(NSString *)container {
    self = [super init];
    if (self) {
        _container = [container copy];
        _endedIDs = [NSMutableArray array];
        _io = dispatch_queue_create("com.openminis.minisight.approval", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (BOOL)pending { return _request != nil && !_settling; }
- (NSString *)requestID { return _request[@"id"]; }
- (void)rememberEnded:(NSString *)ident {
    if (!ident.length || [_endedIDs containsObject:ident]) return;
    [_endedIDs addObject:ident];
    if (_endedIDs.count > 64) [_endedIDs removeObjectAtIndex:0];
}
- (void)sendCancelled:(NSDictionary *)request challenge:(NSString *)challenge {
    if (!request[@"id"] || !challenge) return;
    NSDictionary *ack = @{@"protocolVersion":@2, @"id":request[@"id"],
        @"challenge":challenge, @"state":@"cancelled"};
    NSString *container = _container;
    dispatch_async(_io, ^{
        if (MSBridgeWrite(container, @"confirm-ack.json", ack))
            MSBridgePost(@"com.openminis.minisight.confirm.ack");
    });
}
- (void)invalidate {
    NSAssert(NSThread.isMainThread, @"approval state is main-thread only");
    NSDictionary *request = _request;
    NSString *challenge = _challenge;
    ++_epoch; ++_readGeneration;
    _request = nil; _challenge = nil; _presented = NO; _settling = NO;
    [self rememberEnded:request[@"id"]];
    // Hide/disable BEFORE any cancellation ACK can be observed by the App.
    if (_dismiss) _dismiss();
    [self sendCancelled:request challenge:challenge];
}
- (void)ackPresented:(NSString *)challenge {
    if (!_request || _settling || !_presented || !MSApprovalUUID(challenge)) return;
    if (!_isVisible || !_isVisible()) { [self invalidate]; return; }
    _challenge = [challenge copy];
    NSDictionary *request = _request;
    NSString *container = _container;
    NSUInteger epoch = _epoch;
    dispatch_async(_io, ^{
        if (!MSApprovalRequestValid(container, request)) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (epoch == self.epoch) [self invalidate]; });
            return;
        }
        __block BOOL stillVisible = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            stillVisible = epoch == self.epoch && self.presented && !self.settling &&
                self.isVisible && self.isVisible();
        });
        if (!stillVisible || MSApprovalRevoked(container, request)) return;
        NSDictionary *ack = @{@"protocolVersion":@2, @"id":request[@"id"],
            @"challenge":challenge, @"state":@"presented"};
        BOOL written = MSBridgeWrite(container, @"confirm-ack.json", ack);
        if (written) MSBridgePost(@"com.openminis.minisight.confirm.ack");
        else dispatch_async(dispatch_get_main_queue(), ^{ if (epoch == self.epoch) [self invalidate]; });
    });
}
- (void)readRequest {
    NSAssert(NSThread.isMainThread, @"approval state is main-thread only");
    NSUInteger readGeneration = ++_readGeneration;
    NSString *container = _container;
    dispatch_async(_io, ^{
        NSDictionary *request = MSBridgeRead(container, @"confirm.json", 131072);
        BOOL valid = MSApprovalRequestValid(container, request);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (readGeneration != self.readGeneration || !valid) return;
            NSString *ident = request[@"id"];
            if ([self.endedIDs containsObject:ident]) return;
            if (self.request) {
                // Immutable content and ID: no overwriting a different request.
                if (![self.request isEqual:request] || self.settling) return;
                [self ackPresented:self.challenge];
                return;
            }
            ++self.epoch;
            self.request = request; self.challenge = request[@"challenge"];
            self.settling = NO;
            NSString *text = MSApprovalText(request);
            self.presented = text.length && self.present && self.present(text);
            if (!self.presented) { [self invalidate]; return; }
            [self ackPresented:self.challenge];
        });
    });
}
- (void)readPing {
    NSAssert(NSThread.isMainThread, @"approval state is main-thread only");
    NSString *container = _container;
    dispatch_async(_io, ^{
        NSDictionary *ping = MSBridgeRead(container, @"confirm-ping.json", 4096);
        NSDictionary *cancel = MSBridgeRead(container, @"confirm-cancel.json", 4096);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.request || self.settling) return;
            if (MSApprovalVersion(cancel) && [cancel[@"id"] isEqual:self.requestID]) {
                [self invalidate]; return;
            }
            if (!MSApprovalVersion(ping) || ![ping[@"id"] isEqual:self.requestID] ||
                !MSApprovalUUID(ping[@"challenge"])) return;
            [self ackPresented:ping[@"challenge"]];
        });
    });
}
- (void)readCancellation {
    NSAssert(NSThread.isMainThread, @"approval state is main-thread only");
    NSString *container = _container;
    dispatch_async(_io, ^{
        NSDictionary *cancel = MSBridgeRead(container, @"confirm-cancel.json", 4096);
        NSDictionary *request = MSBridgeRead(container, @"confirm.json", 131072);
        NSDictionary *ping = MSBridgeRead(container, @"confirm-ping.json", 4096);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!MSApprovalVersion(cancel) || !MSApprovalUUID(cancel[@"id"])) return;
            NSString *ident = cancel[@"id"];
            [self rememberEnded:ident];
            if ([self.requestID isEqual:ident]) {
                // A newer ping may have been written before its event arrived.
                if (MSApprovalVersion(ping) && [ping[@"id"] isEqual:ident] && MSApprovalUUID(ping[@"challenge"]))
                    self.challenge = ping[@"challenge"];
                [self invalidate];
            } else if (!self.request && MSApprovalVersion(request) && [request[@"id"] isEqual:ident]) {
                // Unavailable pet/no window: still ACK that there is no stale UI.
                NSString *challenge = request[@"challenge"];
                if (MSApprovalVersion(ping) && [ping[@"id"] isEqual:ident]) challenge = ping[@"challenge"];
                if (MSApprovalUUID(challenge)) [self sendCancelled:request challenge:challenge];
            }
        });
    });
}
- (void)answer:(BOOL)allow {
    NSAssert(NSThread.isMainThread, @"approval state is main-thread only");
    if (!_request || _settling || !_presented || !_isVisible || !_isVisible()) return;
    NSDictionary *request = _request;
    NSUInteger epoch = _epoch;
    NSString *container = _container;
    _settling = YES;
    if (_dismiss) _dismiss(); // Buttons disabled before any asynchronous result.
    dispatch_async(_io, ^{
        BOOL valid = MSApprovalRequestValid(container, request);
        NSDictionary *ack = MSBridgeRead(container, @"confirm-ack.json", 4096);
        // Do not produce an unacknowledged allow, even if a UI callback fires.
        valid = valid && MSApprovalVersion(ack) && [ack[@"id"] isEqual:request[@"id"]] &&
            [ack[@"state"] isEqual:@"presented"];
        __block BOOL current = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{ current = epoch == self.epoch && self.settling; });
        if (valid && current && !MSApprovalRevoked(container, request)) {
            NSDictionary *result = @{@"protocolVersion":@2, @"id":request[@"id"], @"allow":@(allow)};
            if (MSBridgeWrite(container, @"confirm-result.json", result))
                MSBridgePost(@"com.openminis.minisight.confirm.result");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (epoch != self.epoch) return;
            [self rememberEnded:request[@"id"]];
            self.request = nil; self.challenge = nil; self.presented = NO; self.settling = NO;
            // Cancellation/fallback remains App-authoritative if the write failed.
        });
    });
}
@end

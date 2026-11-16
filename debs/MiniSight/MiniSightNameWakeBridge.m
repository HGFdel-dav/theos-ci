#import "MiniSightNameWakeBridge.h"
#import "MiniSightBridgeIO.h"
NSString *const MSNWRequestNote = @"com.openminis.minisight.namewake.request";
NSString *const MSNWResponseNote = @"com.openminis.minisight.namewake.response";
NSString *const MSNWStateNote = @"com.openminis.minisight.namewake.state";
static const NSUInteger MSNWLimit = 8191;
static BOOL MSNWStringUUID(id value) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    return MSNWUUID(bytes.bytes, bytes.length);
}
static BOOL MSNWNumber(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
}
/* Validate the cached container without rediscovering UUID directories per pulse. */
static BOOL MSNWContainerValid(NSString *container) {
    if (!container.length) return NO;
    int root = open(container.fileSystemRepresentation, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (root < 0) return NO;
    int fd = openat(root, ".com.apple.mobile_container_manager.metadata.plist", O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    close(root); if (fd < 0) return NO;
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > 65536) { close(fd); return NO; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    size_t used = 0;
    while (used < data.length) {
        ssize_t n = read(fd, (char *)data.mutableBytes + used, data.length - used);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        used += (size_t)n;
    }
    close(fd); if (used != data.length) return NO;
    id meta = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
    return [meta isKindOfClass:NSDictionary.class] && [meta[@"MCMMetadataIdentifier"] isEqual:@"com.openminis.app"];
}
static BOOL MSNWWriteVerified(NSString *container, NSString *name, NSDictionary *value) {
    if (!MSNWContainerValid(container)) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!data.length || data.length > MSNWLimit) return NO;
    int dir = MSBridgeDirectory(container); if (dir < 0) return NO;
    struct stat st;
    int result = fstatat(dir, name.fileSystemRepresentation, &st, AT_SYMLINK_NOFOLLOW);
    BOOL safe = result == 0 ? (S_ISREG(st.st_mode) && st.st_size >= 0 && (uint64_t)st.st_size <= MSNWLimit) : errno == ENOENT;
    close(dir);
    return safe && MSBridgeWrite(container, name, value) &&
        [MSBridgeRead(container, name, MSNWLimit) isEqualToDictionary:value];
}
@implementation MiniSightNameWakeBridge {
    dispatch_queue_t _queue;
    NSString *_host;
    NSUInteger _stateTicket, _responseTicket, _readTicket;
}
+ (instancetype)sharedBridge {
    static MiniSightNameWakeBridge *value; static dispatch_once_t once;
    dispatch_once(&once, ^{ value = [MiniSightNameWakeBridge new]; }); return value;
}
- (instancetype)init {
    if ((self = [super init])) {
        _host = NSUUID.UUID.UUIDString;
        _queue = dispatch_queue_create("com.openminis.minisight.namewake.mailbox", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (NSString *)host { return _host; }
- (BOOL)request:(NSDictionary *)request matchesRevision:(NSString *)revision {
    if (![request isKindOfClass:NSDictionary.class] || request.count != 6 || !revision.length || revision.length > 128) return NO;
    if (!MSNWNumber(request[@"schema"]) || [request[@"schema"] doubleValue] != 1 ||
        !MSNWNumber(request[@"clock"]) || !MSNWClockFresh(NSProcessInfo.processInfo.systemUptime, [request[@"clock"] doubleValue], 3)) return NO;
    return MSNWStringUUID(request[@"host"]) && [request[@"host"] isEqualToString:self.host] &&
        [request[@"revision"] isKindOfClass:NSString.class] && [request[@"revision"] isEqualToString:revision] &&
        MSNWStringUUID(request[@"token"]) && [request[@"action"] isKindOfClass:NSString.class] &&
        [@[@"hit", @"ready", @"cancel"] containsObject:request[@"action"]];
}
- (void)publishContainer:(NSString *)container revision:(NSString *)revision unlocked:(BOOL)unlocked allowed:(BOOL)allowed busy:(BOOL)busy {
    NSAssert(NSThread.isMainThread, @"Name wake host state is main-thread owned");
    container = [container copy]; revision = [revision copy] ?: @"";
    NSDictionary *entry = @{@"schema": @1, @"clock": @(NSProcessInfo.processInfo.systemUptime), @"host": self.host,
        @"revision": revision, @"unlocked": @(unlocked), @"allowed": @(allowed && unlocked && revision.length > 0 && revision.length <= 128), @"busy": @(busy)};
    __block NSUInteger ticket; @synchronized (self) { ticket = ++_stateTicket; }
    dispatch_async(_queue, ^{
        @synchronized (self) { if (ticket != self->_stateTicket) return; }
        if (!MSNWClockFresh(NSProcessInfo.processInfo.systemUptime, [entry[@"clock"] doubleValue], 4)) return;
        BOOL verified = MSNWWriteVerified(container, @"namewake-state.json", entry);
        @synchronized (self) { if (ticket != self->_stateTicket) return; }
        if (verified) MSBridgePost(MSNWStateNote);
    });
}
- (void)readRequestInContainer:(NSString *)container revision:(NSString *)revision completion:(void (^)(NSDictionary *))completion {
    NSAssert(NSThread.isMainThread, @"Name wake requests enter on main");
    container = [container copy]; revision = [revision copy];
    __block NSUInteger ticket; @synchronized (self) { ticket = ++_readTicket; }
    dispatch_async(_queue, ^{
        @synchronized (self) { if (ticket != self->_readTicket) return; }
        NSDictionary *request = MSNWContainerValid(container) ? MSBridgeRead(container, @"namewake-request.json", MSNWLimit) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (self) { if (ticket != self->_readTicket) return; }
            if (completion) completion([self request:request matchesRevision:revision] ? request : nil);
        });
    });
}
- (void)replyToRequest:(NSDictionary *)request container:(NSString *)container state:(NSString *)state
    responseGeneration:(NSUInteger)responseGeneration voiceGeneration:(NSUInteger)voiceGeneration reason:(NSString *)reason {
    NSAssert(NSThread.isMainThread, @"Name wake responses enter on main");
    if (!MSNWStringUUID(request[@"token"]) || ![request[@"host"] isEqualToString:self.host] ||
        ![@[@"accepted", @"voice_requested", @"cancelled", @"declined"] containsObject:state]) return;
    NSDictionary *entry = @{@"schema": @1, @"clock": @(NSProcessInfo.processInfo.systemUptime), @"host": self.host,
        @"revision": request[@"revision"] ?: @"", @"token": request[@"token"], @"state": state,
        @"responseGeneration": @(responseGeneration), @"voiceGeneration": @(voiceGeneration), @"reason": reason ?: @""};
    container = [container copy];
    __block NSUInteger ticket; @synchronized (self) { ticket = ++_responseTicket; }
    dispatch_async(_queue, ^{
        @synchronized (self) { if (ticket != self->_responseTicket) return; }
        if (!MSNWClockFresh(NSProcessInfo.processInfo.systemUptime, [entry[@"clock"] doubleValue], 3)) return;
        BOOL verified = MSNWWriteVerified(container, @"namewake-response.json", entry);
        @synchronized (self) { if (ticket != self->_responseTicket) return; }
        if (verified) {
            MSBridgePost(MSNWResponseNote);
            // Named voice.json was written by the panel first. The App may now
            // claim its generation from the already-verified ready response.
            if ([state isEqualToString:@"voice_requested"] && voiceGeneration != 0)
                MSBridgePost(@"com.openminis.minisight.voice");
        }
    });
}
@end

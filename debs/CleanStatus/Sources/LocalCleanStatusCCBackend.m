#import "LocalCleanStatusCCBackend.h"
#import "LocalCleanStatusCCDiagnostics.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

// ABI shapes below are rebuilt from the QuickCC2 2.0.1 static analysis
// (see CleanStatus-cc-research-20261106/quickcc2/API-EVIDENCE.md). Only the
// argument positions actually proven there are used; unknown callback slots
// stay opaque and are never read.

typedef struct __WiFiManager *LCSCWiFiManager;
typedef struct __WiFiDeviceClient *LCSCWiFiDevice;
typedef struct __WiFiNetwork *LCSCWiFiNetwork;
typedef void (*LCSCScanCallback)(LCSCWiFiDevice device, CFArrayRef results, int32_t error, void *context);
typedef void (*LCSAssociateCallback)(LCSCWiFiDevice device, LCSCWiFiNetwork network,
                                     uintptr_t unknown, int32_t error, void *context);

typedef struct {
    void *handle;
    LCSCWiFiManager (*create)(CFAllocatorRef, int32_t);
    void (*schedule)(LCSCWiFiManager, CFRunLoopRef, CFStringRef);
    void (*unschedule)(LCSCWiFiManager, CFRunLoopRef, CFStringRef);
    CFArrayRef (*copyDevices)(LCSCWiFiManager);
    CFArrayRef (*copyNetworks)(LCSCWiFiManager);
    LCSCWiFiNetwork (*copyCurrent)(LCSCWiFiDevice);
    int32_t (*scan)(LCSCWiFiDevice, CFDictionaryRef, LCSCScanCallback, void *);
    int32_t (*associate)(LCSCWiFiDevice, LCSCWiFiNetwork, LCSAssociateCallback, void *);
    CFStringRef (*ssid)(LCSCWiFiNetwork);
    CFTypeRef (*property)(LCSCWiFiNetwork, CFStringRef);
    int32_t (*isWEP)(LCSCWiFiNetwork);
    int32_t (*isWPA)(LCSCWiFiNetwork);
    int32_t (*isEAP)(LCSCWiFiNetwork);
    BOOL ready;
} LCSCWiFiAPI;

@implementation LCSCCTarget
- (void)setRaw:(id)raw {
    if (_raw == raw) return;
    if (_raw) CFRelease((__bridge CFTypeRef)_raw);
    _raw = raw ? (__bridge id)CFRetain((__bridge CFTypeRef)raw) : nil;
}
- (void)dealloc { if (_raw) CFRelease((__bridge CFTypeRef)_raw); }
@end

@interface LCSCCBackend ()
@property(nonatomic) LCSCWiFiManager manager;
@property(nonatomic) LCSCWiFiDevice device;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) NSUInteger scanGeneration;
@property(nonatomic) BOOL scanRunning;
@end

static void *LCSCCWiFiHandle;
static LCSCWiFiAPI LCSCCWiFi;
static NSString * const LCSCCWiFiFramework = @"/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi";

static void LCSCCLoadWiFi(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen(LCSCCWiFiFramework.fileSystemRepresentation, RTLD_LAZY);
        if (!handle) { local_cleanstatus_ccLog(@"wifi.load",@"dlopen-failed"); return; }
        LCSCCWiFi.handle = handle;
        BOOL ok = YES;
#define LCSCC_SYM(field,name) do { *(void **)(&LCSCCWiFi.field)=dlsym(handle,name); if(!LCSCCWiFi.field) ok=NO; } while(0)
        LCSCC_SYM(create,"WiFiManagerClientCreate");
        LCSCC_SYM(copyDevices,"WiFiManagerClientCopyDevices");
        LCSCC_SYM(copyNetworks,"WiFiManagerClientCopyNetworks");
        LCSCC_SYM(copyCurrent,"WiFiDeviceClientCopyCurrentNetwork");
        LCSCC_SYM(scan,"WiFiDeviceClientScanAsync");
        LCSCC_SYM(associate,"WiFiDeviceClientAssociateAsync");
        LCSCC_SYM(ssid,"WiFiNetworkGetSSID");
        LCSCC_SYM(property,"WiFiNetworkGetProperty");
        LCSCC_SYM(isWEP,"WiFiNetworkIsWEP");
        LCSCC_SYM(isWPA,"WiFiNetworkIsWPA");
        LCSCC_SYM(isEAP,"WiFiNetworkIsEAP");
        LCSCC_SYM(schedule,"WiFiManagerClientScheduleWithRunLoop");
        LCSCC_SYM(unschedule,"WiFiManagerClientUnscheduleFromRunLoop");
#undef LCSCC_SYM
        LCSCCWiFi.ready = ok;
        if (!ok) local_cleanstatus_ccLog(@"wifi.symbols",@"missing");
    });
}

static NSString *LCSCCString(CFStringRef value) {
    return value ? (__bridge_transfer NSString *)CFRetain(value) : nil;
}

static void LCSCCScanCallback(LCSCWiFiDevice,CFArrayRef,int32_t,void *);
static void LCSCCAssociateCallback(LCSCWiFiDevice,LCSCWiFiNetwork,uintptr_t,int32_t,void *);

@implementation LCSCCBackend
+ (instancetype)shared {
    static LCSCCBackend *instance; static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[LCSCCBackend alloc] init]; });
    return instance;
}
- (instancetype)init {
    if ((self = [super init])) _queue = dispatch_queue_create("com.local.cleanstatus.cc", DISPATCH_QUEUE_SERIAL);
    return self;
}

#pragma mark - Wi-Fi

- (BOOL)wiFiAvailable {
    LCSCCLoadWiFi();
    if (!LCSCCWiFi.ready) return NO;
    if (!self.manager) {
        self.manager = LCSCCWiFi.create(kCFAllocatorDefault, 0);
        if (!self.manager) return NO;
        LCSCCWiFi.schedule(self.manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        CFArrayRef devices = LCSCCWiFi.copyDevices(self.manager);
        if (devices) {
            if (CFArrayGetCount(devices) > 0) self.device = (LCSCWiFiDevice)CFArrayGetValueAtIndex(devices, 0);
            CFRelease(devices);
        }
    }
    return self.device != NULL;
}

- (void)scanWiFi:(LCSCCListHandler)handler {
    NSUInteger generation = ++self.scanGeneration;
    if (![self wiFiAvailable]) {
        handler(@[], [NSError errorWithDomain:@"CleanStatusCC" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Wi-Fi 不可用"}]);
        return;
    }
    void *context = (__bridge_retained void *)[handler copy];
    self.scanRunning = YES;
    int32_t status = LCSCCWiFi.scan(self.device, NULL, LCSCCScanCallback, context);
    if (status != 0) {
        self.scanRunning = NO;
        CFBridgingRelease(context);
        handler(@[], [NSError errorWithDomain:@"CleanStatusCC" code:(NSInteger)status
            userInfo:@{NSLocalizedDescriptionKey:@"扫描启动失败"}]);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), self.queue, ^{
        if (generation == self.scanGeneration && self.scanRunning) {
            self.scanRunning = NO;
            local_cleanstatus_ccLog(@"wifi.scan",@"timeout");
        }
    });
}

static void LCSCCScanCallback(LCSCWiFiDevice device, CFArrayRef results, int32_t error, void *context) {
    (void)device;
    LCSCCListHandler handler = (__bridge_transfer LCSCCListHandler)context;
    LCSCCBackend *backend = LCSCCBackend.shared;
    backend.scanRunning = NO;
    NSMutableArray *targets = [NSMutableArray array];
    if (error == 0 && results) {
        CFIndex count = CFArrayGetCount(results);
        for (CFIndex i = 0; i < count; i++) {
            LCSCWiFiNetwork network = (LCSCWiFiNetwork)CFArrayGetValueAtIndex(results, i);
            NSString *ssid = LCSCCString(LCSCCWiFi.ssid(network));
            if (!ssid.length) continue;
            LCSCCTarget *target = [LCSCCTarget new];
            target.title = ssid;
            target.raw = (__bridge id)network;
            CFStringRef key = CFSTR("RSSI");
            CFTypeRef value = LCSCCWiFi.property ? LCSCCWiFi.property(network, key) : NULL;
            NSInteger rssi = [(__bridge id)value isKindOfClass:NSNumber.class] ? [(__bridge id)value integerValue] : -90;
            target.subtitle = rssi > -60 ? @"▂▄▆█" : (rssi > -75 ? @"▂▄▆_" : @"▂___");
            target.secure = (LCSCCWiFi.isWEP && LCSCCWiFi.isWEP(network)) ||
                            (LCSCCWiFi.isWPA && LCSCCWiFi.isWPA(network)) ||
                            (LCSCCWiFi.isEAP && LCSCCWiFi.isEAP(network));
            [targets addObject:target];
        }
        [targets sortUsingComparator:^NSComparisonResult(LCSCCTarget *a, LCSCCTarget *b) {
            return [a.title localizedCaseInsensitiveCompare:b.title];
        }];
    }
    NSError *failure = error == 0 ? nil : [NSError errorWithDomain:@"CleanStatusCC" code:error
        userInfo:@{NSLocalizedDescriptionKey:@"扫描失败"}];
    handler(targets, failure);
}

- (void)joinWiFi:(LCSCCTarget *)target completion:(LCSCCActionResult)completion {
    if (!self.device || !target.raw) { completion(NO, nil); return; }
    void *context = (__bridge_retained void *)[completion copy];
    int32_t status = LCSCCWiFi.associate(self.device, (__bridge LCSCWiFiNetwork)target.raw,
                                         LCSCCAssociateCallback, context);
    if (status != 0) {
        CFBridgingRelease(context);
        completion(NO, [NSError errorWithDomain:@"CleanStatusCC" code:status
            userInfo:@{NSLocalizedDescriptionKey:@"连接请求失败"}]);
    }
}

static void LCSCCAssociateCallback(LCSCWiFiDevice device, LCSCWiFiNetwork network,
                                   uintptr_t unknown, int32_t error, void *context) {
    (void)device; (void)network; (void)unknown;
    LCSCCActionResult result = (__bridge_transfer LCSCCActionResult)context;
    result(error == 0, error == 0 ? nil : [NSError errorWithDomain:@"CleanStatusCC" code:error
        userInfo:@{NSLocalizedDescriptionKey:@"连接失败"}]);
}

#pragma mark - Bluetooth

static Class LCSCCBluetoothManagerClass(void) {
    static Class cls; static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);
        cls = NSClassFromString(@"BluetoothManager");
    });
    return cls;
}

- (id)bluetoothManager {
    Class cls = LCSCCBluetoothManagerClass();
    SEL selector = sel_registerName("sharedInstance");
    return (cls && [cls respondsToSelector:selector]) ? ((id(*)(id,SEL))objc_msgSend)(cls, selector) : nil;
}
- (BOOL)bluetoothAvailable { return self.bluetoothManager != nil; }

- (NSString *)stringOf:(id)object selector:(const char *)name {
    SEL selector = sel_registerName(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    id value = ((id(*)(id,SEL))objc_msgSend)(object, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

- (void)listPairedBluetooth:(LCSCCListHandler)handler {
    id manager = self.bluetoothManager;
    SEL paired = sel_registerName("pairedDevices");
    SEL connected = sel_registerName("connectedDevices");
    if (!manager || ![manager respondsToSelector:paired]) {
        handler(@[], [NSError errorWithDomain:@"CleanStatusCC" code:2 userInfo:@{NSLocalizedDescriptionKey:@"蓝牙不可用"}]);
        return;
    }
    NSArray *devices = ((id(*)(id,SEL))objc_msgSend)(manager, paired);
    NSSet *connectedSet = [manager respondsToSelector:connected]
        ? [NSSet setWithArray:((id(*)(id,SEL))objc_msgSend)(manager, connected)] : [NSSet set];
    NSMutableArray *targets = [NSMutableArray array];
    for (id device in devices) {
        NSString *name = [self stringOf:device selector:"name"];
        NSString *address = [self stringOf:device selector:"address"];
        if (!name.length) name = address ?: @"未命名设备";
        LCSCCTarget *target = [LCSCCTarget new];
        target.title = name; target.subtitle = address ?: @""; target.raw = device;
        target.connected = [connectedSet containsObject:device];
        [targets addObject:target];
    }
    [targets sortUsingComparator:^NSComparisonResult(LCSCCTarget *a, LCSCCTarget *b) {
        if (a.connected != b.connected) return a.connected ? NSOrderedAscending : NSOrderedDescending;
        return [a.title localizedCaseInsensitiveCompare:b.title];
    }];
    handler(targets, nil);
}

- (void)toggleBluetooth:(LCSCCTarget *)target completion:(LCSCCActionResult)completion {
    id manager = self.bluetoothManager;
    if (!manager || !target.raw) { completion(NO, nil); return; }
    const char *name = target.connected ? "disconnectDevice:" : "connectDevice:";
    SEL selector = sel_registerName(name);
    if (![manager respondsToSelector:selector]) { completion(NO, nil); return; }
    ((void(*)(id,SEL,id))objc_msgSend)(manager, selector, target.raw);
    completion(YES, nil);
}
@end

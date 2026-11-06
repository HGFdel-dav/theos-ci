#import "LocalCleanStatusCCBackend.h"
#import "LocalCleanStatusCCRuntime.h"
#import "LocalCleanStatusCCEnvironment.h"
#import "LocalCleanStatusCCDiagnostics.h"
#import <dlfcn.h>
#include <stdint.h>

// Existing QuickCC2 static evidence: scan callback x1/results,w2/error,x3/token;
// associate x1/network,x2/unused,w3/error,x4/token. Never conflate the callbacks.
typedef struct __WiFiManager *LCSWiFiManager;
typedef struct __WiFiDeviceClient *LCSWiFiDevice;
typedef struct __WiFiNetwork *LCSWiFiNetwork;
typedef void (*LCSScanCB)(void *,void *,void *,void *);
typedef void (*LCSAssociateCB)(void *,void *,void *,void *,void *);
typedef struct {
    void *handle;
    LCSWiFiManager (*create)(CFAllocatorRef,int32_t);
    void (*schedule)(LCSWiFiManager,CFRunLoopRef,CFStringRef);
    CFArrayRef (*copyDevices)(LCSWiFiManager);
    CFArrayRef (*copyNetworks)(LCSWiFiManager);
    LCSWiFiNetwork (*copyCurrent)(LCSWiFiDevice);
    int32_t (*scan)(LCSWiFiDevice,CFDictionaryRef,LCSScanCB,void *);
    int32_t (*associate)(LCSWiFiDevice,LCSWiFiNetwork,LCSAssociateCB,void *);
    CFStringRef (*ssid)(LCSWiFiNetwork);
    CFTypeRef (*property)(LCSWiFiNetwork,CFStringRef);
    int32_t (*isWEP)(LCSWiFiNetwork);
    int32_t (*isWPA)(LCSWiFiNetwork);
    int32_t (*isEAP)(LCSWiFiNetwork);
    BOOL ready;
} LCSWiFiAPI;
static LCSWiFiAPI lcscc_wifi;
static void lcscc_scanCallback(void *,void *,void *,void *);
static void lcscc_associateCallback(void *,void *,void *,void *,void *);

@implementation LCSCCTarget
@synthesize networkRef=_networkRef;
- (void)setNetworkRef:(CFTypeRef)ref {
    if (ref==_networkRef) return;
    if (ref) CFRetain(ref);
    if (_networkRef) CFRelease(_networkRef);
    _networkRef=ref;
}
- (void)dealloc { if (_networkRef) CFRelease(_networkRef); }
@end

@interface LCSCCNativeRequest : NSObject
@property(nonatomic) uintptr_t token;
@property(nonatomic) CFArrayRef scanResults; // manually retained; not an NSArray
@property(nonatomic,copy) LCSCCListHandler list;
@property(nonatomic,copy) LCSCCActionResult action;
@property(nonatomic,strong) LCSCCTarget *target;
@property(nonatomic) BOOL desiredConnection;
@end
@implementation LCSCCNativeRequest
@end

@interface LCSCCBackend ()
@property(nonatomic) LCSWiFiManager manager;
@property(nonatomic) LCSWiFiDevice device;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,LCSCCNativeRequest *> *requests;
@property(nonatomic) uintptr_t nextToken;
@property(nonatomic,strong) NSMutableArray *bluetoothObservers;
@property(nonatomic,copy) dispatch_block_t bluetoothChanged;
- (void)receivedScanRef:(CFArrayRef)results error:(int32_t)error token:(uintptr_t)token;
- (BOOL)hasRequest:(uintptr_t)token;
- (void)receivedAssociate:(int32_t)error token:(uintptr_t)token;
- (void)verifyAction:(uintptr_t)token attempts:(NSUInteger)attempts;
@end

static NSError *lcscc_error(NSInteger code,NSString *reason) {
    return [NSError errorWithDomain:@"CleanStatusCC" code:code userInfo:@{NSLocalizedDescriptionKey:reason}];
}
static NSArray *lcscc_array(id value) {
    if ([value isKindOfClass:NSArray.class]) return value;
    if ([value isKindOfClass:NSSet.class]) return [value allObjects];
    return @[];
}
static NSString *lcscc_ssid(LCSWiFiNetwork network) {
    if (!network || !lcscc_wifi.ssid) return nil;
    CFStringRef s=lcscc_wifi.ssid(network);
    return s && CFGetTypeID(s)==CFStringGetTypeID()?(__bridge_transfer NSString *)CFRetain(s):nil;
}
static void lcscc_loadWiFi(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        void *h=dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi",RTLD_LAZY);
        if (!h) return;
        lcscc_wifi.handle=h;
        BOOL ready=YES;
#define LCS_WIFI(field,symbol) do { *(void **)(&lcscc_wifi.field)=dlsym(h,symbol); if(!lcscc_wifi.field)ready=NO; } while(0)
        LCS_WIFI(create,"WiFiManagerClientCreate");
        LCS_WIFI(schedule,"WiFiManagerClientScheduleWithRunLoop");
        LCS_WIFI(copyDevices,"WiFiManagerClientCopyDevices");
        LCS_WIFI(copyNetworks,"WiFiManagerClientCopyNetworks");
        LCS_WIFI(copyCurrent,"WiFiDeviceClientCopyCurrentNetwork");
        LCS_WIFI(scan,"WiFiDeviceClientScanAsync");
        LCS_WIFI(associate,"WiFiDeviceClientAssociateAsync");
        LCS_WIFI(ssid,"WiFiNetworkGetSSID");
        LCS_WIFI(property,"WiFiNetworkGetProperty");
        LCS_WIFI(isWEP,"WiFiNetworkIsWEP");
        LCS_WIFI(isWPA,"WiFiNetworkIsWPA");
        LCS_WIFI(isEAP,"WiFiNetworkIsEAP");
#undef LCS_WIFI
        // Manager lives for this process. The unproven unschedule signature is
        // not called; no per-modal manager teardown while callbacks are alive.
        lcscc_wifi.ready=ready;
        local_cleanstatus_ccLog(@"wifi.symbols",ready?@"ready":@"missing");
    });
}

@implementation LCSCCBackend
+ (instancetype)shared {
    static LCSCCBackend *b; static dispatch_once_t once;
    dispatch_once(&once,^{b=[LCSCCBackend new];}); return b;
}
- (instancetype)init {
    if ((self=[super init])) { _requests=[NSMutableDictionary new]; _bluetoothObservers=[NSMutableArray new]; }
    return self;
}
- (BOOL)wiFiAvailable { lcscc_loadWiFi(); return lcscc_wifi.ready; }
- (BOOL)prepareWiFi {
    if (![self wiFiAvailable] || !NSThread.isMainThread) return NO;
    if (!self.manager) {
        self.manager=lcscc_wifi.create(kCFAllocatorDefault,0);
        if (self.manager) lcscc_wifi.schedule(self.manager,CFRunLoopGetMain(),kCFRunLoopDefaultMode);
    }
    if (!self.manager) return NO;
    if (!self.device) {
        CFArrayRef devices=lcscc_wifi.copyDevices(self.manager);
        if (devices) {
            if (CFArrayGetCount(devices)>0) self.device=(LCSWiFiDevice)CFRetain(CFArrayGetValueAtIndex(devices,0));
            CFRelease(devices);
        }
    }
    return self.device!=NULL;
}
- (LCSCCNativeRequest *)requestWithTimeout:(NSTimeInterval)timeout {
    NSAssert(NSThread.isMainThread,@"CC requests must be serialized on main");
    // Tokens are opaque integers, not pointers to released blocks. Never reuse
    // a token, including after timeout/cancel; late native calls safely miss.
    if (self.nextToken==UINTPTR_MAX || self.requests.count>=64) return nil;
    LCSCCNativeRequest *r=[LCSCCNativeRequest new]; r.token=++self.nextToken;
    self.requests[@(r.token)]=r;
    uintptr_t token=r.token;
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(timeout*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        [weakSelf finish:token success:NO items:nil error:lcscc_error(LCSCCErrorTimeout,@"等待超时，请下拉刷新后重试")];
    });
    return r;
}
- (void)finish:(uintptr_t)token success:(BOOL)success items:(NSArray *)items error:(NSError *)error {
    LCSCCNativeRequest *r=self.requests[@(token)]; if (!r) return;
    [self.requests removeObjectForKey:@(token)];
    if (r.scanResults) { CFRelease(r.scanResults); r.scanResults=NULL; }
    if (r.list) r.list(items?:@[],error);
    if (r.action) r.action(success,error);
}
- (BOOL)hasRequest:(uintptr_t)token {
    return token!=0 && self.requests[@(token)]!=nil;
}
- (void)cancelRequests {
    NSAssert(NSThread.isMainThread,@"CC cancellation must be serialized on main");
    for (LCSCCNativeRequest *request in self.requests.allValues)
        if (request.scanResults) { CFRelease(request.scanResults); request.scanResults=NULL; }
    [self.requests removeAllObjects];
}

- (NSString *)currentSSID {
    if (!self.device) return nil;
    LCSWiFiNetwork current=lcscc_wifi.copyCurrent(self.device);
    NSString *ssid=lcscc_ssid(current);
    if (current) CFRelease(current);
    return ssid;
}
- (NSSet<NSString *> *)knownSSIDs {
    NSMutableSet *known=[NSMutableSet new];
    CFArrayRef networks=lcscc_wifi.copyNetworks(self.manager);
    if (networks) {
        for (CFIndex i=0;i<CFArrayGetCount(networks);i++) {
            NSString *s=lcscc_ssid((LCSWiFiNetwork)CFArrayGetValueAtIndex(networks,i));
            if (s.length) [known addObject:s];
        }
        CFRelease(networks);
    }
    return known;
}
- (void)scanWiFi:(LCSCCListHandler)handler {
    if (!handler) return;
    if (!local_cleanstatus_ccUnlocked() || ![self prepareWiFi]) {
        handler(@[],lcscc_error(LCSCCErrorUnavailable,@"Wi-Fi 接口未就绪，请打开无线局域网后下拉刷新")); return;
    }
    for (LCSCCNativeRequest *r in self.requests.allValues)
        if (r.list) { handler(@[],lcscc_error(LCSCCErrorUnavailable,@"正在扫描，请稍候")); return; }
    LCSCCNativeRequest *r=[self requestWithTimeout:8];
    if (!r) { handler(@[],lcscc_error(LCSCCErrorUnavailable,@"请求队列已满")); return; }
    r.list=handler;
    // MobileWiFi rejects a NULL parameter dictionary outright (-3900), which is
    // why the list stayed empty; the reference passes an empty dictionary.
    int32_t status=lcscc_wifi.scan(self.device,(__bridge CFDictionaryRef)@{},lcscc_scanCallback,(void *)r.token);
    if (status) [self finish:r.token success:NO items:nil
        error:lcscc_error(status,[NSString stringWithFormat:@"扫描未启动（%d）",status])];
}
- (void)receivedScanRef:(CFArrayRef)results error:(int32_t)error token:(uintptr_t)token {
    // A stale or cancelled request owns a reference we must drop here.
    LCSCCNativeRequest *request=self.requests[@(token)];
    if (!request) { if (results) CFRelease(results); return; }
    if (request.scanResults) { CFRelease(request.scanResults); request.scanResults=NULL; }
    request.scanResults=results;
    if (!local_cleanstatus_ccUnlocked()) { [self cancelRequests]; return; }
    if (error) { [self finish:token success:NO items:nil error:lcscc_error(error,@"扫描失败，请下拉刷新")]; return; }
    NSSet *known=[self knownSSIDs]; NSString *current=[self currentSSID];
    NSMutableDictionary<NSString *,LCSCCTarget *> *unique=[NSMutableDictionary new];
    CFIndex count=results?CFArrayGetCount(results):0;
    for (CFIndex index=0;index<count;index++) {
        LCSWiFiNetwork network=(LCSWiFiNetwork)CFArrayGetValueAtIndex(results,index);
        NSString *ssid=lcscc_ssid(network); if (!ssid.length) continue;
        LCSCCTarget *row=[LCSCCTarget new]; row.identifier=ssid; row.title=ssid;
        row.networkRef=(CFTypeRef)network;
        row.saved=[known containsObject:ssid]; row.connected=[ssid isEqualToString:current];
        row.state=row.connected?2:0;
        row.secure=lcscc_wifi.isWEP(network)||lcscc_wifi.isWPA(network)||lcscc_wifi.isEAP(network);
        CFTypeRef value=lcscc_wifi.property(network,CFSTR("RSSI"));
        row.rssi=value && CFGetTypeID(value)==CFNumberGetTypeID()?[(__bridge NSNumber *)value integerValue]:-90;
        row.signalLevel=row.rssi>-61?1.0:(row.rssi>-73?0.66:0.33);
        row.subtitle=@"";
        LCSCCTarget *old=unique[ssid];
        if (!old || row.rssi>old.rssi || row.connected) unique[ssid]=row;
    }
    NSArray *rows=[unique.allValues sortedArrayUsingComparator:^NSComparisonResult(LCSCCTarget *a,LCSCCTarget *b){
        if (a.state!=b.state) return a.state>b.state?NSOrderedAscending:NSOrderedDescending;
        return [a.title localizedStandardCompare:b.title];
    }];
    [self finish:token success:YES items:rows error:nil];
}
- (void)joinWiFi:(LCSCCTarget *)target completion:(LCSCCActionResult)completion {
    if (!completion) return;
    if (!local_cleanstatus_ccUnlocked() || ![self prepareWiFi] || !target.networkRef) {
        completion(NO,lcscc_error(LCSCCErrorUnavailable,@"连接接口不可用")); return;
    }
    if (target.secure && !target.saved && !target.connected) {
        completion(NO,lcscc_error(LCSCCErrorOpenSettings,@"需要在无线局域网设置中输入密码")); return;
    }
    if ([[self currentSSID] isEqualToString:target.identifier]) { completion(YES,nil); return; }
    for (LCSCCNativeRequest *pending in self.requests.allValues)
        if (pending.action) { completion(NO,lcscc_error(LCSCCErrorUnavailable,@"正在处理连接，请稍候")); return; }
    LCSCCNativeRequest *r=[self requestWithTimeout:15];
    if (!r) { completion(NO,lcscc_error(LCSCCErrorUnavailable,@"请求队列已满")); return; }
    r.target=target; r.action=completion; r.desiredConnection=YES;
    int32_t status=lcscc_wifi.associate(self.device,(LCSWiFiNetwork)target.networkRef,
        lcscc_associateCallback,(void *)r.token);
    if (status) [self finish:r.token success:NO items:nil error:lcscc_error(status,@"连接请求被拒绝")];
}
- (void)receivedAssociate:(int32_t)error token:(uintptr_t)token {
    if (!self.requests[@(token)]) return;
    if (error) { [self finish:token success:NO items:nil error:lcscc_error(error,@"连接失败，请检查网络")]; return; }
    // Associate status=0 is not enough: only an actual currentSSID match makes
    // the UI checkmark/success state. Verification is bounded to six seconds.
    [self verifyAction:token attempts:12];
}

#pragma mark - paired Bluetooth devices, not nearby discovery
- (id)bluetoothManager {
    static void *handle; static dispatch_once_t once;
    dispatch_once(&once,^{handle=dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager",RTLD_LAZY);});
    if (!handle) return nil;
    return lcscc_object(NSClassFromString(@"BluetoothManager"),"sharedInstance");
}
- (BOOL)bluetoothAvailable {
    id manager=[self bluetoothManager];
    return lcscc_can(manager,"pairedDevices",@encode(id));
}
- (void)listPairedBluetooth:(LCSCCListHandler)handler {
    if (!handler) return;
    id manager=[self bluetoothManager];
    if (!local_cleanstatus_ccUnlocked() || !lcscc_can(manager,"pairedDevices",@encode(id))) {
        handler(@[],lcscc_error(LCSCCErrorUnavailable,@"蓝牙设备接口不可用")); return;
    }
    if (!lcscc_bool(manager,"powered",YES)) {
        handler(@[],lcscc_error(LCSCCErrorUnavailable,@"蓝牙已关闭，请在蓝牙设置中开启")); return;
    }
    NSMutableArray *rows=[NSMutableArray new];
    for (id device in lcscc_array(lcscc_object(manager,"pairedDevices"))) {
        id addr=lcscc_object(device,"address"),name=lcscc_object(device,"name");
        if (![addr isKindOfClass:NSString.class] || ![addr length]) continue;
        LCSCCTarget *row=[LCSCCTarget new]; row.identifier=addr;
        row.title=[name isKindOfClass:NSString.class] && [name length]?name:addr;
        row.bluetoothDevice=device; row.connected=lcscc_bool(device,"connected",NO);
        row.state=row.connected?2:0; row.subtitle=row.connected?@"已连接":@"未连接";
        [rows addObject:row];
    }
    [rows sortUsingComparator:^NSComparisonResult(LCSCCTarget *a,LCSCCTarget *b){
        if(a.state!=b.state)return a.state>b.state?NSOrderedAscending:NSOrderedDescending;
        return [a.title localizedCaseInsensitiveCompare:b.title];
    }];
    handler(rows,nil);
}
- (BOOL)invokeBluetooth:(id)device connecting:(BOOL)connecting {
    SEL sel=sel_registerName(connecting?"connect":"disconnect");
    Method method=device?class_getInstanceMethod(object_getClass(device),sel):NULL;
    if (!method || method_getNumberOfArguments(method)!=2) return NO;
    char *type=method_copyReturnType(method); const char *t=lcscc_type(type);
    BOOL isVoid=t && !strcmp(t,"v"),isInt=t && !strcmp(t,"i"); free(type);
    // Both void/int32 variants exist in dumped system versions; never call an
    // object/structure ABI via this scalar function pointer.
    if (isVoid) { ((void(*)(id,SEL))objc_msgSend)(device,sel); return YES; }
    if (isInt) return ((int(*)(id,SEL))objc_msgSend)(device,sel)==0;
    return NO;
}
- (void)toggleBluetooth:(LCSCCTarget *)target completion:(LCSCCActionResult)completion {
    if (!completion) return;
    if (!local_cleanstatus_ccUnlocked() || !target.bluetoothDevice) {
        completion(NO,lcscc_error(LCSCCErrorUnavailable,@"蓝牙设备接口不可用")); return;
    }
    for (LCSCCNativeRequest *pending in self.requests.allValues)
        if (pending.action) { completion(NO,lcscc_error(LCSCCErrorUnavailable,@"正在处理设备连接")); return; }
    LCSCCNativeRequest *r=[self requestWithTimeout:15];
    if (!r) { completion(NO,lcscc_error(LCSCCErrorUnavailable,@"请求队列已满")); return; }
    r.target=target; r.action=completion;
    r.desiredConnection=!lcscc_bool(target.bluetoothDevice,"connected",NO);
    if (![self invokeBluetooth:target.bluetoothDevice connecting:r.desiredConnection]) {
        [self finish:r.token success:NO items:nil error:lcscc_error(LCSCCErrorUnavailable,@"设备连接请求不可用或已被拒绝")]; return;
    }
    [self verifyAction:r.token attempts:30];
}
- (void)verifyAction:(uintptr_t)token attempts:(NSUInteger)attempts {
    LCSCCNativeRequest *r=self.requests[@(token)]; if(!r)return;
    if (!local_cleanstatus_ccUnlocked()) { [self cancelRequests]; return; }
    BOOL matched=r.target.bluetoothDevice?
        lcscc_bool(r.target.bluetoothDevice,"connected",NO)==r.desiredConnection:
        [[self currentSSID] isEqualToString:r.target.identifier];
    if(matched){ [self finish:token success:YES items:nil error:nil]; return; }
    if(!attempts){ [self finish:token success:NO items:nil error:lcscc_error(LCSCCErrorTimeout,@"连接状态尚未确认，请下拉刷新")];return; }
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(),^{
        [weakSelf verifyAction:token attempts:attempts-1];
    });
}
- (void)startBluetoothUpdates:(dispatch_block_t)changed {
    [self stopBluetoothUpdates]; self.bluetoothChanged=changed;
    for (NSString *name in @[@"BluetoothDeviceConnectSuccessNotification",@"BluetoothDeviceConnectFailedNotification",
          @"BluetoothDeviceDisconnectSuccessNotification",@"BluetoothDevicePairedNotification",
          @"BluetoothDeviceUnpairedNotification",@"BluetoothPowerChangedNotification"]) {
        __weak typeof(self) weakSelf=self;
        id observer=[NSNotificationCenter.defaultCenter addObserverForName:name object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
                (void)note;
                typeof(self) strongSelf=weakSelf;
                if(strongSelf.bluetoothChanged) strongSelf.bluetoothChanged();
            }];
        [self.bluetoothObservers addObject:observer];
    }
}
- (void)stopBluetoothUpdates {
    for (id observer in self.bluetoothObservers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    [self.bluetoothObservers removeAllObjects]; self.bluetoothChanged=nil;
}
@end

// The framework invokes the callback either as (device, results, error, context)
// or block-shaped as (results, error, context). Instead of guessing, both
// candidate slots are offered to the token registry: only a live token is
// accepted, and the results slot is dereferenced only for that layout.
static void lcscc_scanCallback(void *a1,void *a2,void *a3,void *a4) {
    uintptr_t first=(uintptr_t)a4,second=(uintptr_t)a3;
    void *resultsSlot=a2,*firstError=a3;
    dispatch_async(dispatch_get_main_queue(),^{
        LCSCCBackend *backend=LCSCCBackend.shared;
        uintptr_t token=0; void *results=NULL; int32_t error=0;
        if ([backend hasRequest:first]) { token=first; results=resultsSlot; error=(int32_t)(intptr_t)firstError; }
        else if ([backend hasRequest:second]) { token=second; results=a1; error=(int32_t)(intptr_t)a2; }
        else return;
        [backend receivedScanRef:results?(CFArrayRef)CFRetain(results):NULL error:error token:token];
    });
}
static void lcscc_associateCallback(void *a1,void *a2,void *a3,void *a4,void *a5) {
    uintptr_t first=(uintptr_t)a5,second=(uintptr_t)a4;
    dispatch_async(dispatch_get_main_queue(),^{
        LCSCCBackend *backend=LCSCCBackend.shared;
        if ([backend hasRequest:first]) [backend receivedAssociate:(int32_t)(intptr_t)a4 token:first];
        else if ([backend hasRequest:second]) [backend receivedAssociate:(int32_t)(intptr_t)a3 token:second];
    });
}

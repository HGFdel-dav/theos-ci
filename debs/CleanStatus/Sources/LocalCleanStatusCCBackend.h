#pragma once
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
typedef NS_ENUM(NSInteger,LCSCCTargetKind) { LCSCCTargetKindWiFi=0,LCSCCTargetKindBluetooth=1 };
typedef NS_ENUM(NSInteger,LCSCCErrorCode) { LCSCCErrorUnavailable=1,LCSCCErrorTimeout=2,LCSCCErrorOpenSettings=3,LCSCCErrorCancelled=4 };
@interface LCSCCTarget : NSObject
@property(nonatomic,copy) NSString *identifier;
@property(nonatomic,copy) NSString *title;
@property(nonatomic,copy) NSString *subtitle;
@property(nonatomic) BOOL secure;
@property(nonatomic) BOOL saved;
@property(nonatomic) BOOL connected;
@property(nonatomic) NSInteger state; // 0 idle, 1 pending, 2 actually connected
@property(nonatomic) NSInteger rssi;
@property(nonatomic) double signalLevel;
@property(nonatomic) CFTypeRef networkRef; // explicitly CFRetain/CFRelease
@property(nonatomic,strong) id bluetoothDevice; // normal ARC object, never CFRelease
@end

typedef void (^LCSCCListHandler)(NSArray<LCSCCTarget *> *targets,NSError *error);
typedef void (^LCSCCActionResult)(BOOL success,NSError *error);
@interface LCSCCBackend : NSObject
+ (instancetype)shared;
- (BOOL)wiFiAvailable;
- (BOOL)bluetoothAvailable;
- (void)scanWiFi:(LCSCCListHandler)handler;
- (void)listPairedBluetooth:(LCSCCListHandler)handler;
- (void)joinWiFi:(LCSCCTarget *)target completion:(LCSCCActionResult)completion;
- (void)toggleBluetooth:(LCSCCTarget *)target completion:(LCSCCActionResult)completion;
- (void)cancelRequests;
- (void)startBluetoothUpdates:(dispatch_block_t)changed;
- (void)stopBluetoothUpdates;
@end

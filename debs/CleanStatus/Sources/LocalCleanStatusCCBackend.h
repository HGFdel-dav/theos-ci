#pragma once
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, LCSCCTargetKind) { LCSCCTargetKindWiFi, LCSCCTargetKindBluetooth };

@interface LCSCCTarget : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *subtitle;
@property(nonatomic) BOOL secure;      // Wi-Fi needs a key
@property(nonatomic) BOOL connected;   // Bluetooth already linked
@property(nonatomic, assign) id raw;  // CF/ObjC pointer, retained manually, see setRaw:
@end

typedef void (^LCSCCListHandler)(NSArray<LCSCCTarget *> *targets, NSError *error);
typedef void (^LCSCCActionResult)(BOOL success, NSError *error);

@interface LCSCCBackend : NSObject
+ (instancetype)shared;
- (BOOL)wiFiAvailable;
- (BOOL)bluetoothAvailable;
- (void)scanWiFi:(LCSCCListHandler)handler;
- (void)listPairedBluetooth:(LCSCCListHandler)handler;
- (void)joinWiFi:(LCSCCTarget *)target completion:(LCSCCActionResult)completion;
- (void)toggleBluetooth:(LCSCCTarget *)target completion:(LCSCCActionResult)completion;
@end

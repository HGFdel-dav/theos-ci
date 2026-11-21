#pragma once
#import <Foundation/Foundation.h>
#import "LCSCellularPolicy.h"

// Shared source, distinct ObjC names in the module versus the injected image.
#if LCS_CELLULAR_DATA_MODULE
#define LCSCellularLine LCSDataModuleLine
#define LCSCellularToken LCSDataModuleToken
#define LCSCellularService LCSDataModuleService
#endif

@interface LCSCellularLine : NSObject <NSCopying>
@property(nonatomic) NSInteger slot;
// Internal identity only. Never emit it, a phone number, or an ICCID to diagnostics.
@property(nonatomic,copy) NSString *identity;
@property(nonatomic,copy) NSString *name;
@property(nonatomic) BOOL available;
@property(nonatomic) BOOL stateKnown;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL selectionKnown;
@property(nonatomic) BOOL selected;
@end

@interface LCSCellularToken : NSObject
@property(atomic,readonly,getter=isCancelled) BOOL cancelled;
- (void)cancel;
@end

typedef void (^LCSCellularReadCompletion)(NSArray<LCSCellularLine *> *lines,NSString *error);
typedef void (^LCSCellularActionCompletion)(BOOL verified,NSArray<LCSCellularLine *> *lines,NSString *error);

@interface LCSCellularService : NSObject
- (instancetype)initWithKind:(LCSCellularKind)kind;
- (void)readWithToken:(LCSCellularToken *)token completion:(LCSCellularReadCompletion)completion;
- (void)selectDataLine:(LCSCellularLine *)line token:(LCSCellularToken *)token completion:(LCSCellularActionCompletion)completion;
- (void)setSIMLine:(LCSCellularLine *)line enabled:(BOOL)enabled confirmed:(BOOL)confirmed
             token:(LCSCellularToken *)token completion:(LCSCellularActionCompletion)completion;
@end

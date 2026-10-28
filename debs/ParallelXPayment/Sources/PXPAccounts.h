#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const PXPAccountsErrorDomain;
FOUNDATION_EXPORT NSString * const PXPDefaultContainerIdentifier;
typedef NS_ERROR_ENUM(PXPAccountsErrorDomain, PXPAccountsErrorCode) {
    PXPAccountsUnavailable = 1,
    PXPAccountsInvalidArgument,
    PXPAccountsUnsupportedABI,
    PXPAccountsInvalidData,
    PXPAccountsCancelled,
    PXPAccountsNotForeground,
    PXPAccountsBusy,
    PXPAccountsTerminationFailed,
    PXPAccountsTimedOut,
    PXPAccountsVerificationFailed
};

// Async completions run once on main. Success always returns a real identifier,
// including @"DEFAULT"; nil is ONLY an error/cancellation, never the default.
// One-account apps do not present UI. No selection preferences are persisted.
FOUNDATION_EXPORT void PXPChooseAccount(
    NSString *bundle,
    void (^completion)(NSString * _Nullable containerID, NSError * _Nullable error));

// Caller must first close its old host/scene and serialize its payment request.
// isCurrent runs on main; it must stay NO after cancellation/transaction timeout.
// Concurrent prepares fail busy (including while a cancelled biometric request
// is still outstanding). No late callback may succeed or finish a newer request.
// NO + error means do not launch. This API does not itself launch any application.
FOUNDATION_EXPORT void PXPPrepareAccount(
    NSString *bundle, NSString *containerID,
    BOOL (^isCurrent)(void),
    void (^completion)(BOOL prepared, NSError * _Nullable error));

// Main-thread only; fail closed off-main. Re-reads Crane, never a UI cache.
// Active-config equality does NOT attest a running process's sandbox/environment.
FOUNDATION_EXPORT BOOL PXPAccountStillMatches(NSString *bundle, NSString *containerID);
FOUNDATION_EXPORT BOOL PXPAccountsAvailable(void);
// Main-thread only; the serialized route owns the only picker.
FOUNDATION_EXPORT void PXPCancelAccountSelection(void);

NS_ASSUME_NONNULL_END

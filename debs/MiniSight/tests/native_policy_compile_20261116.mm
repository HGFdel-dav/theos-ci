// Compile only on an authorized CI runner against the exact iPhoneOS15.5 SDK.
// Logos makes Tweak.xm Objective-C++; every production policy must parse there.
#import <Foundation/Foundation.h>
#import "MiniSightPet.h"
#include "MiniSightGeometry.h"
#include "MiniSightLayout.h"
#include "MiniSightBubbleLayout.h"
#include "MiniSightChatLayout.h"
#include "MiniSightGravity.h"
#include "MiniSightRegionSelection.h"
#include "MiniSightMotionPolicy.h"
#include "MiniSightPetBehavior.h"
#include "MiniSightPetMusicMotion.h"
#include "MiniSightLiveliness.h"
#include "MiniSightNameWakeGate.h"
#include "MiniSightNameWakeProtocol.h"
#include "MiniSightNameWakeState.h"
#include "MiniSightMusicPresentationPolicy.h"
#include "MiniSightShownReadback.h"
#include "MiniSightApprovalSummaryCore.h"
#include "tools/recorder/MiniSightRecorderCore.h"

// Keep enum initialization explicit in C as well as C++: integer zero is not
// a valid implicit C++ enum conversion. No casts of integer/object/PAC pointers.
void MSNativePolicyCompileFixture(void) {
    MSMotionAttempt motion = {0, MSMotionSourceNone, 0};
    MSMotionStart(&motion, 1, 1);
    (void)MSMotionAccepts(&motion, motion.generation, MSMotionSourceDevice, 1);
    MSPetResidentTransition transition = MSPetResidentUnchanged;
    MiniSightPetMotionLockReason reason = MiniSightPetMotionLockHost;
    (void)transition; (void)reason;
    (void)MSApprovalDescribe("true");
    (void)MSNWReadyMayConsume(true, false, 1, true, true, false);
    (void)MSNameWakeMayStartInput(1, 1, 1, true, true, false, false, false, false);
}

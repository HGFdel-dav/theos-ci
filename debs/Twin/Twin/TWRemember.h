// TWRemember.h — per-entry ("bundleID|containerID") panel shape snapshot.
// ScreenCore-style: the wide-window memory (p/l) and the docked/compact memory
// (dp/dl + ratios) are stored apart, so a narrow docked frame can never pollute
// the wide window memory.
//
// State dictionary (plist-safe, all values are NSString/NSNumber/NSDate/NSDictionary):
//   p        {x,y,w,h}  portrait (竖屏) frame of the wide window
//   l        {x,y,w,h}  landscape (横屏) frame of the wide window
//   docked   BOOL       panel width < screen width * 0.55
//   side     NSNumber   0 = panel centre left of screen centre, 1 = right
//   updated  NSDate     last capture
//   dp / dl  {x,y,w,h}  narrow frame captured while docked (docked memory only)
//   dw/dh/dy NSNumber    that docked frame as ratios of the screen, so the
//                        restore can scale the width to the current screen width
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Idempotent. Installs the ParallelX (PXPanelEntry) hooks when that class is
// present and runs the one-shot migration of the legacy TWKeyRememberFrames.
FOUNDATION_EXPORT void TWRememberStart(void);

// Snapshot for one entry, or nil when nothing is remembered. containerID may be
// nil/empty for the default container.
FOUNDATION_EXPORT NSDictionary *TWRememberStateForEntry(NSString *bundleID, NSString *containerID);

// Merge-stores a snapshot for one entry (nil/empty removes the entry).
FOUNDATION_EXPORT void TWRememberStoreState(NSString *bundleID, NSString *containerID, NSDictionary *state);

// Every remembered entry, newest first:
// [{key,bundleID,containerID,p,l,docked,side,updated,dp,dl,dw,dh,dy,summary,sizeText,stateText}]
FOUNDATION_EXPORT NSArray<NSDictionary *> *TWRememberAllStates(void);

// 「重置记忆大小及位置」— drops every entry (and the legacy frame store).
FOUNDATION_EXPORT void TWRememberResetAll(void);
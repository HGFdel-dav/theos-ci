# Research / header evidence

Retrieved 2026-10-30. Runtime invocation sequence is not proved by a header.

## Toolchain
- https://github.com/roothide/Developer/blob/master/README.md — use roothide/theos + THEOS_PACKAGE_SCHEME=roothide, official jbroot() for the active root. Do not scan random historical roots for runtime preferences.
- https://github.com/roothide/theos — toolchain compatible with rootless and RootHide schemes.
- https://github.com/opa334/Dopamine/tree/2.x — rootless semi-untethered environment; compatible OS range includes A14 / 15.5.
- https://github.com/tealbathingsuit/ellekit — current reachable ElleKit source/docs, Substrate API reimplementation and arm64e hooks; dependency/API only, no copied hook implementation.

## iOS 15.5 exact ABI
Downloaded headers originate at:
https://github.com/lechium/iPhone_OS_15.5/tree/master/System/Library/PrivateFrameworks/
Each local header retains its classdump copyright header. Header repository MIT license: see HEADERS-LICENSE.txt.

- UserNotificationsUIKit/NCNotificationListCell.h: `- (void)_executeClearAction`.
- UserNotificationsUIKit/NCNotificationStructuredListViewController.h:
  - `- (void)notificationListComponent:requestsClearingNotificationRequests:` (objects)
  - `- (void)notificationListComponent:requestsClearingNotificationRequestsInSections:` (objects)
  - `- (void)notificationListComponentRequestsClearingAllNotificationRequests:` (object)
  - `masterListView` object getter.
- UserNotificationsUIKit/NCNotificationViewController.h: `notificationRequest` object getter.
- SpringBoardHome/SBHIconManager.h: `- (void)removeIcon:(id)icon options:(unsigned long long)options completion:(Block)completion`.
  - Block invocation signature deliberately not guessed; passed to original unchanged.
- SpringBoardHome/SBIcon.h: `isWidgetIcon`, `isWidgetStackIcon` both `_Bool`.
- SpringBoardHome/SBIconView.h: `icon` object getter.
- ControlCenterUIKit/CCUIContinuousSliderView.h: `- (void)_handleValueChangeGestureRecognizer:(id)gesture`.
- ControlCenterUIKit/CCUIBaseSliderView.h: `value` is float (NOT double/id).

## Selected implementation
Private methods are looked up dynamically and return + each argument checked before MSHookMessageEx. Unknown signatures skip with diagnostic log. No global UIView removal hook. Original deletion method executes exactly once with original parameters and block; visual capture does not modify native view visibility. Control center observes native gesture AFTER original processing, never writes system brightness/volume.

## Not proved without runtime test
- Whether every swipe/clear-all route on this exact device reaches these callbacks.
- `requestsClearingNotificationRequestsInSections:` payload shape: current matching recognizes section identifiers if getter is present; unknown objects are not coerced.
- Whether the GPU-backed widget renderer appears fully in drawViewHierarchy snapshot.
- Other Control Center replacements must preserve CCUIContinuousSliderView to obtain particles.
- Device visuals, latency and coexistence with other tweaks require installation/gesture testing. Cloud compilation alone is not proof.

# API evidence and runtime boundaries

CleanStatus 0.1.4 is original implementation, not a fork of the reference tweaks. All sources below are consulted for API declarations only. Runtime ABI checks are mandatory and skip unsupported methods. No claim of iOS15.5 device verification is made.

## Status data
- RuntimeBrowser UIKitCore headers: https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/UIKitCore.framework/UIStatusBar_Modern.h
  - instance `- (void)_updateWithData:(id)data force:(bool)force`.
- https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/UIKitCore.framework/_UIStatusBarData.h
  - `NSCopying`, copy object properties airplaneModeEntry, alarmEntry, bluetoothEntry, assistantEntry, carPlayEntry, quietModeEntry, locationEntry, rotationLockEntry, cellularEntry, secondaryCellularEntry, vpnEntry, wifiEntry.
- https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/UIKitCore.framework/_UIStatusBarDataEntry.h
  - `NSCopying`, `bool isEnabled`, `void setEnabled:(bool)`.
- https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/UIKitCore.framework/UIStatusBar_Base.h
  - `void forceUpdateData:(bool)` for a one-time first layout refresh.

Display source and each selected entry are copied. Original incoming data is retained independently for Apply/off restoration. We do not alter CoreTelephony, location, VPN, Focus, Wi-Fi, Siri, or CarPlay service state. Assistant/CarPlay controls apply only when these data entries produce a status icon; they never hide Siri UI/privacy indicators or vehicle UI.

## Battery
- https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/UIKitCore.framework/_UIBatteryView.h
  - double chargePercent; long long chargingState; bool saverModeActive; bodyLayer, fillLayer, pinLayer, boltLayer, percentageLabel.
- iOS15-specific declaration/selector cross-check (source is GPL; no implementation copied):
  https://github.com/MTACS/Ampere/blob/1.1/Ampere.h
  https://github.com/MTACS/Ampere/blob/1.1/Ampere.xm
  - confirms `bodyShapeLayer`, `bodyLayer`, `fillLayer`, `pinLayer`, `chargePercent`, `chargingState == 1`, `saverModeActive`, `_shouldShowBolt`, `percentageLabel` on the iOS15 path.
- https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/UIKitCore.framework/_UIStatusBarItem.h
  - bool canEnableDisplayItem:(id)item fromData:(id)data.
- https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/UIKitCore.framework/_UIStatusBarBatteryItem.h
  - class object methods chargingDisplayIdentifier, percentDisplayIdentifier; scoped display suppression.
- https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/UIKitCore.framework/_UIStatusBarDisplayItem.h
  - object identifier.

Modern battery is an independent small UIView canvas, limited to status bar ancestry. Original layer opacities are restored before native layout and when disabled; native charge and power state are not overwritten. No timer, UIDevice battery monitoring, IOKit polling or GPU particle load. Missing native body/fill/charge selectors make the modern rendering fail closed. A static-only battery variant and other status tweaks may require later device-specific adaptation. Native touch-routing ancestors may vary; the tap hit target needs device testing.

## Low Power
- https://github.com/nst/iOS-Runtime-Headers/blob/master/PrivateFrameworks/CoreDuet.framework/_CDBatterySaver.h
  - class `id batterySaver`; instance `long long getPowerMode`; instance `bool setPowerMode:(long long)mode error:(id *)error`.
- Ampere 1.1 source confirms the `_CDBatterySaver` route used before iOS16 `_PMLowPowerMode`.
- Lock checking uses SBLockScreenManager sharedInstance/isUILocked and additionally validates the runtime return type. Unknown state denies the action; not device-confirmed in this project.

Darwin IPC requests toggle only in SpringBoard, when the applied master/tap feature is ON, unlocked, not in-flight and outside a 650ms debounce. Darwin notify provides no sender identity; it is not an authentication boundary. Another local process knowing the notification could request a toggle while enabled/unlocked. Normal applications never directly call the privileged power mutation.

## Evidence limits
RuntimeBrowser headers are not a release-specific dump of this user's device. iOS15 declarations are cross-checked where possible; presence/encoding guards prevent guessed-ABI calls but do not prove a feature executed. Exact iOS15.5 behavior, layout, override interactions, hidden icon space reclamation, wallpaper contrast, static battery, accessibility, touch routing and power mutation require installed testing after separate authorization.

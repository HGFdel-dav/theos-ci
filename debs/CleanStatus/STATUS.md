# CleanStatus 0.3.9 — cellular direct entry, local candidate

## Confirmed baseline

The device readback on 2026-11-23 was `com.local.cleanstatus` **0.3.8** arm64e. The user's 10.288 s video shows the cellular tile first opening the stock six-button Connectivity panel and only then the existing “蜂窝管理” card; the Wi-Fi tile presents its list directly from collapsed Control Center. No new SpringBoard crash report was present.

The 08:22 diagnostics in the 0.3.8 session contained `08:22:17 button-not-visible`, `08:22:18 bound-direct-only` and `08:22:19 sim-manager present`, so the card was reachable and could read subscriptions. Those records do not contain a real hit-test, system recognizer state, or expanded-state trace. The exact reason the six-button panel wins is therefore not yet directly observed.

## Source comparison

`Sources/LocalCleanStatusControlCenter.m` (Wi-Fi/Bluetooth) has a local touch check, a region-limited window fallback, an own recognizer delegate with a failure-priority rule and a `CCUIRoundButton` method hook. `Cellular/LCSCellularHooks.m` in 0.3.8 only attached a standard long press directly to the button and required direct touch. The cellular path had no equivalent collapsed-state routing.

## 0.3.9 scope

Starts from published 0.3.8 commit `4f819236e3468c27acda3e1ff7bf49a0a976124a`, frozen in `docs/BASELINE-038-ENTRY.json`. Only the cellular entrance and its tests/version/records are intended to differ. Wi-Fi/Bluetooth, the existing SIM card, SIM service, helper, entitlements, DataSwitch and Preferences storage are byte-identical to 0.3.8.

### Entrance changes

- A standard `UILongPressGestureRecognizer` (0.45 s, 10 pt, one finger, cancels touches only when recognized) is installed on the nearest non-control UIKit/ControlCenter ancestor inside the verified cellular module content, never on a window or outside that content.
- Its target/delegate is a separate `NSObject` implementing only public recognizer-delegate methods. There is no `UIGestureRecognizer` subclass, no `owner` property, no forwarding and no native `CCUIRoundButton` method hook.
- A touch is accepted only when its hit view is related to the cellular button and its initial point is inside the button bounds. `previewInteractionShouldBegin:` on `CCUIContentModuleContainerViewController` is hooked only after image/ABI checks; it returns NO only for this native container, this exact interaction, a live cellular attempt and a collapsed-at-touch attempt whose initial point is inside the button. All other calls run the original.
- Native pan/long-press gestures in this same module are not given a failure dependency over this cellular attempt; ordinary taps still wait, preserving the native short toggle. Other modules and their gestures are untouched. There is no broad non-pan rule.
- The existing SIM controller presentation, single-panel guard, lock/OFF/foreground cleanup and read-back contract are reused unchanged.

### Safety fallback

If the private container/method/local-host checks fail, the code falls back to the 0.3.8 button-attached long press. That fallback preserves the existing two-step behaviour rather than removing the card. The candidate does not claim direct entry in that case.

## Verification state

- Portable production policy executable: 7,225 assertions across all gate combinations, exact regions, one touch per attempt, early release/cancel, expanded-at-touch, other containers/interactions, finite/finite-boundary cases and null input.
- Cellular entry adapter source contracts: 37; SIM-plan/entry source contract: 153; frozen 0.3.8 files 132 unchanged.
- Cellular policy: 6,291; cellular source/preservation: 161; general invariants: 461; UI structure: 40; card layout C: 1,248; path reuse: 174; panel routes: 10.
- Verifier synthetics: 46 + 11 precise-entitlement + 198 DER; path model 37.
- Fixed iOS 15.5 arm64e SDK `-fsyntax-only` passed for the modified `Cellular/LCSCellularHooks.m`.
- Apple Foundation service fixtures cannot execute on this Alpine host. CI, DEB packaging/verification, injection/load and real touch arbitration remain unverified.

Not yet verified on device: one continuous long press opening the SIM card with zero six-button frames; short tap staying a single native toggle; movement/cancel/rapid-repeat handling; lock/feature-off native fallback; Wi-Fi, Bluetooth, DataSwitch and helper behavior after installation. The private preview selector is evidenced by an older runtime-header snapshot, not a 15.5 device dump; fail-closed ABI checks and the legacy fallback limit the damage if it is absent.

## Authorization

The user approved local implementation and subsequently authorized pushing this 0.3.9 direct-entry candidate and running its dedicated GitHub CI. Installation, device writes, SIM operations, logout and restart remain unauthorized. The last verified phone version is 0.3.8. CI, DEB packaging/verification and the actual direct-entry behavior below are pending at the time of this source snapshot; final results belong in the separate release report.

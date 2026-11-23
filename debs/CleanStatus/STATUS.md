# CleanStatus 0.3.11 — round-button allow hook for cellular long press (local candidate)

## Confirmed device evidence

The phone was on 0.3.10 arm64e. Diagnostics from the failing attempt show `bound-wifi-entry` → `began-wifi` → `sim-manager present`; the card opened, but the user video still showed the stock six-button panel. There was no new SpringBoard crash. Thus 0.3.10's own long press ran, yet the stock panel still won.

## 0.3.10 source gap and 0.3.11 local review corrections

The published 0.3.10 source had a button long press and the Wi-Fi-style pan/tap failure rule, but **did not install a `CCUIRoundButton -gestureRecognizerShouldBegin:` hook**. It therefore never had the Wi-Fi source's selective button-allow mechanism; only the generic recognizer attached to the button could run.

During the first 0.3.11 local draft, an attempted round-button bypass contained duplicate function text and invoked a target callback that was missing. A source/compile review caught these before any build or push. The final local candidate now has one hook and implements `gestureRecognizerShouldBegin:` on the independent target; the hook allows only the exact recognizer stored by the cellular button state and calls the saved native IMP for all other recognizers. A pure policy test and source contracts cover this wiring. This still does not prove the runtime system calls the hook in the expected order.

## 0.3.11 local changes

- One deduplicated `LCSRoundGestureShouldBegin` implementation is installed only after the exact `CCUIRoundButton` image and selector ABI validate.
- The hook identifies the exact `UILongPressGestureRecognizer` retained by this cellular button state. For that recognizer, it calls the same safe eligibility check on the independent `NSObject` target/delegate. Every other gesture calls the saved original implementation. No window-wide hook or `didMoveToWindow` hook is installed.
- Added a portable `LCSRoundButtonAllowsGesture` policy and 12 real C checks for own/native recognizers. Source contracts also assert the native original forwarding path.
- Button-level layout retry, standard recognizer, Wi-Fi failure-direction rule, preview accelerator, and existing SIM-card presentation remain otherwise unchanged. SIM service/helper and DataSwitch source remain byte-identical to the published baseline.

## Verification state

- Fixed iOS 15.5 arm64e SDK `-fsyntax-only` passed for `Cellular/LCSCellularHooks.m`; no machine code was generated locally.
- Portable round-button allowlist policy: 12 checks; button-priority source contract: 141; Wi-Fi-style entry adapter contract: 36; cellular frozen-source contract: 159, with 133 unchanged 0.3.8 files.
- Cellular policy 6,291; source/preservation 165; general invariants 464; UI structure 40; card-layout C 1,248; path reuse 175; panel routes 10. Verifier synthetics: 46 + 11 precise-entitlement + 198 DER; path model 37.
- Apple Foundation fixtures are skipped on Alpine. CI/DEB, injection/load, actual round-button delegate invocation, one-long-press direct presentation, short-tap behavior and six-button suppression remain unverified.

## Authorization

The user approved pushing this 0.3.11 candidate and running its dedicated GitHub CI. Installation, device writes, SIM operations, logout and restart remain unauthorized. The phone remains on 0.3.10; the direct-entry behavior is not yet device-verified.

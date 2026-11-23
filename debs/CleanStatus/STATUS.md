# CleanStatus 0.3.10 — WiFi-style cellular entry (local candidate)

## Confirmed device baseline

The phone was running 0.3.9 arm64e. The 0.3.9 diagnostics recorded `preview-signature-unavailable` at 10:16:33, `bound-legacy-fallback` at 10:16:42 and `began-legacy` at 10:16:44; the existing SIM card then appeared after the stock six-button Connectivity panel. There was no new SpringBoard crash report.

That is direct evidence that 0.3.9 did not enter its new local host at all: the grouped private-preview signature check failed and the code deliberately used the 0.3.8 button fallback. The exact missing preview method was not distinguished by the old log.

## Scope

Starts from published 0.3.8 commit `4f819236e3468c27acda3e1ff7bf49a0a976124a`, frozen in `docs/BASELINE-039-WIFI-ENTRY.json` (143 files). Only the cellular button entry, its tests/version/records differ. The 0.3.9 preview/local-host/entry-policy experiment is not carried forward. Wi-Fi/Bluetooth, SIM service, SIM panel, helper, entitlements and DataSwitch are byte-identical to 0.3.8.

## Entry changes

- Standard one-finger `UILongPressGestureRecognizer` on the unique native cellular `CCUIRoundButton`; independent `NSObject` target/delegate; no recognizer/UIKit subclass, no private `owner`, no forwarding and no native `CCUIRoundButton` method hook.
- `shouldBeRequiredToFailByGestureRecognizer:` uses the Wi-Fi direction: NO for pan, YES for other gestures. Short tap is not replaced.
- `previewInteractionShouldBegin:` is optional. Only that single method is ABI-checked and hooked; it returns NO only for a live cellular touch on this button in the verified container, with the point inside the button and the module collapsed. All other calls forward exactly. No `contentViewController`, `previewInteraction` or `isExpanded` getter is required. Missing method/ABI is logged as `preview-shouldbegin-unavailable` and does not disable the button entry.
- Native expansion is tracked through `containerWillTransitionToExpandedContentMode:`; the existing SIM card, single-panel guard and foreground/lock cleanup are reused.
- Diagnostics now distinguish `preview-container-unavailable`, `preview-shouldbegin-unavailable`, `preview-shouldbegin-installed`, `bound-wifi-entry` and `began-wifi`.

## Verification state

- WiFi-style entry adapter source contracts: 33.
- Cellular WiFi-entry source contract: 153; frozen 0.3.8 files 132 unchanged.
- Cellular policy: 6,291; cellular source/preservation: 162; general invariants: 458; UI structure: 40; card layout C: 1,248; path reuse: 174; panel routes: 10.
- Verifier synthetics: 46 + 11 precise-entitlement + 198 DER; path model 37.
- Fixed iOS 15.5 arm64e SDK `-fsyntax-only` passed for `Cellular/LCSCellularHooks.m`.
- Apple Foundation service fixtures cannot execute on this Alpine host. CI, DEB packaging/verification, injection/load and real touch arbitration remain unverified.

Not yet verified on device: one continuous long press opening the SIM card with zero six-button frames; short tap remaining a single native toggle; movement/cancel/lock/feature-off paths; whether the preview method exists on 15.5 and whether the Wi-Fi failure rule wins over the stock expander. The button entry does not depend on the preview method, but direct presentation still needs device confirmation. Wi-Fi/Bluetooth/DataSwitch/helper behavior after installation also needs regression.

## Authorization

The user approved local implementation and subsequently authorized pushing this 0.3.10 WiFi-style entry candidate and running its dedicated GitHub CI. Installation, device writes, SIM operations, logout and restart remain unauthorized. The last verified phone version is 0.3.9. CI, DEB packaging/verification and the direct-entry behavior below are pending at the time of this source snapshot; final results belong in the separate release report.

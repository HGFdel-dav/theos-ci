# CleanStatus 0.3.12 — known-collapsed entry and bounded diagnostics

## Status and authorization

Local candidate only, based on published 0.3.11 commit `1a36ffc4f9657841369348203c9c2bcdf9114f64`, exact 151-file source archive SHA256 `9dde4c7b7603629ac5d4d8ec7b6d3543b71a7182c403f52f3e44fa1e41630317`. User approved local implementation/validation. No commit, push, CI, iOS machine-code build, device connection/change, SIM action, installation, respring or restart is authorized/performed in this stage.

The 0.3.11 phone/version/log/video observations were obtained in the preceding authorized read-only phase. They are not a 0.3.12 runtime result. Its own round-button callback ran and the card appeared, but the recording includes multiple interactions and had a six-control system page already visible before the logged cellular begin. The same-touch source of the first expansion is unproven. No automatic request for another reboot or repeat recording follows from this work.

## Critical correction: gesture failure direction

Apple's official **Preferring one gesture over another** guide attaches the delegate to a swipe recognizer, returns true from `shouldBeRequiredToFailBy` when `other` is a pan, and comments: **“Do not begin the pan until the swipe fails.”** Thus YES makes OTHER wait for OWN failure, not the reverse. Earlier conversation/notes describing `!UIPan` as “own waits other” were wrong and are superseded here. The actual 0.3.11 rule remains unchanged. This line is not established as the cause of the device failure.

Official references:
- https://developer.apple.com/documentation/uikit/preferring-one-gesture-over-another
- https://developer.apple.com/documentation/uikit/uigesturerecognizerdelegate/gesturerecognizer(_:shouldberequiredtofailby:)

Mature QuickCC2 iOS15 static evidence in `shared/CleanStatus-cc-research-20261106/quickcc2/API-EVIDENCE.md` supports tracking expanded mode and `!expanded` gating, but its initial nil/false state and private/custom recognizer mechanisms are not device proof for this candidate. No owner/subclass/forwarding/window fallback is reintroduced.

## Final production scope

1. `Cellular/LCSCellularEntryPolicy.h`: `LCSCellularMayBeginPress` permits only the exact owned recognizer, known `Collapsed` state, and the existing local eligibility gates. `Unknown`, `Expanded` and invalid enum values are refused.
2. `Cellular/LCSCellularHooks.m`: lifecycle required mask is 47 (original load/appear/disappear/layout plus the already-existing expansion transition hook). `expansionKnown` starts false; **only an observed `containerWillTransitionToExpandedContentMode:` callback marks it known**. `viewDidLoad` / `viewDidAppear` do not invent a collapsed state. Unbind invalidates pending diagnostic snapshots but never changes the last observed expansion state.
3. Begin, actual `Began` action, optional preview scope and panel `mayContinue` all enforce the state. Original native lifecycle methods forward once. The original behavior of closing a live card when expansion occurs remains.
4. Round-button hook invokes the saved original exactly once for every other/native recognizer and returns its original decision unchanged; only the exact owned recognizer uses the local gate. **No type-guessed native blocker, no forced recognizer failure, no new failure dependency rule.** Temporary draft `block-native` / `BlocksNativeBegin` / `ShouldYieldToOther` experiments were removed before verification, not packaged or installed.
5. Read-only trace captures own touch/action, expansion transition, limited button/ancestor/window gesture inventory, relation/simultaneous callbacks, native round-button decisions, and a single weak/generation-guarded delayed snapshot. Class text is normalized to `a-z._-` and capped at 48 characters; no identity, carrier, SSID, phone number, point coordinate, raw object description or pointer is recorded. Existing RootHide-safe preference/diagnostic storage, diagnostics switch and 128-event/32KiB ring remain byte-identical.
6. Each traced owned touch gets at most 36 gesture/class log rows; trace admission is rate-limited to .75s. Even a throttled/new touch increments the generation and invalidates the previous .7s delayed callback. Unbind/OFF/lock/foreground loss/changed binding prevents the late snapshot. No timer changes UIKit gesture states or sends control actions. Inventory visits at most 12 ancestors and 4 other recognizers per snapshot.

## Explicit limitations / expected effect

This is **not a demonstrated direct-open fix**. Unknown initial state deliberately fails closed for the plugin but leaves native interactions untouched. If UIKit does not report a collapsed transition on first opening, the first plugin long press will not show the SIM card; it may work only after a real collapsed callback. The “open from expanded six-control page” fallback from 0.3.11 is intentionally disabled as approved for collapsed-only operation. Current snapshots may omit the real expander if it is outside the sampled ancestry/first four objects, or changes between snapshots. A missing own `shouldReceiveTouch:` log is a blind spot, not proof of a specific recognizer winning. A class name is not sufficient proof of expander identity. Native/original callback logging observes only the known cellular button and only during budgeted attempts.

Do not broaden suppression based on class alone. Further intervention needs the real trace, an explained plan, and new authorization. Short-tap ON/OFF, lock/OFF fallback and cancellation still require UIKit/device verification after a separately authorized build/install.

## Protected behavior and local coverage

All Wi-Fi/Bluetooth/main/animation sources, configuration/persistence/path/notification code, SIM service/helper/entitlements/card, data-module implementation, icons and setting rows are protected against exact 0.3.11 bytes. Only entry source/header, matching tests, package/version metadata, baseline and documentation change. No new settings or permission.

Local gates: production-C unknown/collapsed/expanded/invalid and callback-order/OFF/unowned cases; three compiled bad predicates must fail at runtime; original round policy and forwarding contracts; full feature/card/path/panel/entitlement/verifier regression; fixed iPhoneOS15.5 arm64e syntax-only. Apple Foundation filesystem, UIKit arbitration, AMFI acceptance, injection/loading, same-touch zero-six-control-frame behavior, SIM toggles and respring/restart persistence are NOT claimed. Source string contracts and C models are not UIKit execution.

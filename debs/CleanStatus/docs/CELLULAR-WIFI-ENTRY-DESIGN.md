# Cellular WiFi-style direct entry (0.3.10 local candidate)

## Device evidence for 0.3.9

The phone was running 0.3.9. Its diagnostics recorded `10:16:33 preview-signature-unavailable`, then `10:16:42 bound-legacy-fallback` and `10:16:44 began-legacy`; the SIM card appeared after the stock six-button panel. No new SpringBoard crash was present.

The preview path required four optional methods (`contentViewController`, `previewInteraction`, `isExpanded`, `previewInteractionShouldBegin:`) and treated any mismatch as unavailable. Because the 0.3.9 log grouped them into one slug, the exact missing method is unknown. The important result is that 0.3.9 never bound the new local host; it deliberately fell back to the old button path.

## 0.3.11 button-priority candidate

The installed 0.3.10 logged `bound-wifi-entry` → `began-wifi` → `sim-manager present`, but the stock six-button panel still won. Reviewing the published 0.3.10 blob confirms it did **not** contain a `CCUIRoundButton` hook at all; the shared delegate rule alone was insufficient. The 0.3.11 local candidate adds one narrowly scoped `CCUIRoundButton -gestureRecognizerShouldBegin:` hook for the exact recognizer retained by the cellular button state. It calls the independent target's implemented begin gate (feature on, unlocked, visible, no touch-down side effect, no duplicate card); every other recognizer calls the saved native IMP. There is no `didMoveToWindow` hook, recognizer subclass, private owner, forwarding, or whole-window recognizer. A portable policy test checks own-vs-native decisions.

## 0.3.10 approach (superseded, not the 0.3.11 implementation)

The 0.3.10 candidate used a button-attached long press and `shouldBeRequiredToFailByGestureRecognizer:`. On the device it logged `began-wifi` and `sim-manager present`, but the six-button expander still won. This demonstrated that source similarity to Wi-Fi was insufficient: the Wi-Fi source also hooks the native round button's `gestureRecognizerShouldBegin:` and lets only its own recognizer begin. The 0.3.10 handoff must not be described as a proven direct-entry implementation.
## Why this is not the old unsafe gesture code

The 0.3.3 crash history involved a `UILongPressGestureRecognizer` subclass with a private `owner` property and delegate forwarding. The 0.3.11 hook is only on the verified `CCUIRoundButton` image, and only bypasses its original begin decision for the exact recognizer retained by the cellular state. The new recognizer remains the standard UIKit class; no private ownership selector, delegate forwarding, window fallback, `didMoveToWindow` hook, or change to the Wi-Fi module is used. If a different recognizer reaches the hook, its original method runs.

## Verification limits

This is still an unproven runtime entry. The device must show that one continuous long press opens the SIM card without a six-button frame, that short tap remains a single native toggle, and that movement/cancel/lock/feature-off paths are safe. The Wi-Fi rule's direction and the preview method's presence on 15.5 must be confirmed by the next device run; current local logs cannot prove either. Wi-Fi/Bluetooth, SIM service, helper, entitlements, card and DataSwitch remain byte-identical to 0.3.8.

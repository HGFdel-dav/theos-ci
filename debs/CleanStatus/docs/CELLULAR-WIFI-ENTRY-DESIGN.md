# Cellular WiFi-style direct entry (0.3.10 local candidate)

## Device evidence for 0.3.9

The phone was running 0.3.9. Its diagnostics recorded `10:16:33 preview-signature-unavailable`, then `10:16:42 bound-legacy-fallback` and `10:16:44 began-legacy`; the SIM card appeared after the stock six-button panel. No new SpringBoard crash was present.

The preview path required four optional methods (`contentViewController`, `previewInteraction`, `isExpanded`, `previewInteractionShouldBegin:`) and treated any mismatch as unavailable. Because the 0.3.9 log grouped them into one slug, the exact missing method is unknown. The important result is that 0.3.9 never bound the new local host; it deliberately fell back to the old button path.

## 0.3.10 approach

The proven Wi-Fi entry uses a button-attached long press with an independent target/delegate and a failure dependency rule (`shouldBeRequiredToFailByGestureRecognizer:` returns NO only for pan). This candidate applies the same entry direction to the cellular button, without the old custom recognizer subclass, `owner` property, forwarding, native `CCUIRoundButton` hook or window-wide interception.

1. A standard one-finger `UILongPressGestureRecognizer` (0.45 s, 10 pt, cancels touches only after recognition) is attached to the unique native cellular `CCUIRoundButton`. Its target/delegate is an independent `NSObject` conforming to `UIGestureRecognizerDelegate`.
2. `shouldBeRequiredToFailByGestureRecognizer:` returns NO for a pan and YES for other gestures, matching the Wi-Fi rule. Short tap is therefore not replaced; no `buttonTapped:`/`_toggleState` hook is installed.
3. The native `CCUIContentModuleContainerViewController -previewInteractionShouldBegin:` is an optional accelerator, not a requirement. It is hooked only if that single method's class image and ABI pass. For a live cellular touch on this button, in the correct container, with the point inside the button and the module still collapsed, it returns NO; every other case calls the original. There is no dependency on `contentViewController`, `previewInteraction` or `isExpanded` getters.
4. Native expansion is tracked through `containerWillTransitionToExpandedContentMode:` so the preview gate is not applied while already expanded. If the preview method is absent or its ABI differs, the log says `preview-shouldbegin-unavailable` and the button entry remains active.
5. The existing SIM card presentation, single-panel guard, lock/OFF/foreground cleanup and read-back contract are reused unchanged.

## Why this is not the old unsafe gesture code

The 0.3.3 crash history involved a `UILongPressGestureRecognizer` subclass with a private `owner` property and delegate forwarding. This candidate has no UIKit/recognizer subclass, no private ownership selector, no forwarding, no entire-window fallback and no `CCUIRoundButton` method hook. It uses only a standard recognizer and a small independent delegate implementing public protocol methods.

## Verification limits

This is still an unproven runtime entry. The device must show that one continuous long press opens the SIM card without a six-button frame, that short tap remains a single native toggle, and that movement/cancel/lock/feature-off paths are safe. The Wi-Fi rule's direction and the preview method's presence on 15.5 must be confirmed by the next device run; current local logs cannot prove either. Wi-Fi/Bluetooth, SIM service, helper, entitlements, card and DataSwitch remain byte-identical to 0.3.8.

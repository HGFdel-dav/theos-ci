# Cellular direct-entry design (0.3.9 local candidate)

## Observed problem

The 0.3.8 video and diagnostics show the cellular tile eventually opening the existing SIM card, but only after the stock six-button Connectivity panel has appeared. Wi-Fi, by contrast, presents its list directly from the collapsed Control Center.

This is an entry-routing difference, not a SIM-service defect. The existing card already lists both subscriptions correctly.

## Why not copy the Wi-Fi block verbatim

The Wi-Fi path contains an own recognizer subclass, a window-level region fallback, a `CCUIRoundButton` method hook and a broad non-pan failure rule. Those choices were appropriate for that module, but the 0.3.3 cellular crash history makes copying the whole block unsafe. The cellular candidate keeps the original SIM card/service/helper untouched and uses only a local, bounded entrance.

## 0.3.9 entrance

1. Hook the native `CCUIContentModuleContainerViewController` instance method `previewInteractionShouldBegin:` only after verifying the class image, return type and argument type. The original is always called for every case not positively owned by the cellular module.
2. In the cellular connectivity controller, find the sole `CCUIRoundButton`, its native module container, its content view, and the nearest non-control UIKit/ControlCenter ancestor inside that content. Never climb outside the module content and never install a window recognizer.
3. Install a standard one-finger `UILongPressGestureRecognizer` with 0.45 s duration and 10 pt movement on that local host. Its target/delegate is an independent NSObject; no UIKit/recognizer subclass, no `owner` property, no forwarding and no native `CCUIRoundButton` method hook.
4. On touch reception require: same host, hit view related to the cellular button, and the initial point inside the button bounds. Native pan/long-press gestures in the same module are not given a failure dependency over this attempt; ordinary taps still wait, preserving the short toggle. Other gestures, Wi-Fi/Bluetooth and other modules are left to the original implementation.
5. `previewInteractionShouldBegin:` returns NO only for this container, this exact interaction, a live cellular attempt and an initial point inside the button. That is intended to stop the six-button preview from winning the same touch. Every other call returns the original result.
6. The existing SIM controller presentation, single-panel guard, cancel/foreground cleanup and read-back logic are reused unchanged.

## Safety fallback

If the private container class, method signature, content image, or local host cannot be verified, the code falls back to the 0.3.8 button-attached long press. It is not a direct-entry fix in that fallback, but it does not remove the existing ability to open the card.

## Evidence limits

The exact runtime arbitration of iOS 15.5 is not observed: there is no hit-test, recognizer-state or expanded-state log. The private preview method appears in an older runtime-header snapshot, not in a 15.5 device dump. The ABI checks are fail-closed, and the fallback preserves old behaviour; neither the direct presentation nor the absence of the six-button panel is claimed until installed and touched on the device.

## Protected behaviour

- Wi-Fi and Bluetooth source/entry/backend: byte-identical to 0.3.8.
- SIM service, SIM panel, helper, entitlements and DataSwitch reads/writes: byte-identical to 0.3.8.
- Native cellular short tap: never replaced; long press is not installed on controls with touch-down side effects.
- Lock, disabled feature, app background, disappearing controller, repeated panel and cancellation all clear the local entrance.

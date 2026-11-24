# CleanStatus 0.3.14 — unified compact/expanded long-press behavior

Local candidate only. No push, CI, package, install, device write, SIM action, respring or restart.

## User acceptance target

Wi-Fi, Bluetooth and Cellular long press must open their own existing overlay regardless of whether the six-control connectivity page is absent, already visible, or appears during the same interaction. Native short taps, Cellular SIM service/helper, DataSwitch and existing safety gates remain unchanged.

## Evidence and correction

0.3.13 real-device behavior: Wi-Fi/Bluetooth worked from compact Control Center but not after the six-control page was opened; Cellular needed the six-control page to appear and return before its panel would open. Prior code comparison showed two opposite gates:

- Wi-Fi/Bluetooth closed the active list when their module reported expanded and `mayContinue` rejected expanded state.
- Cellular rejected unknown/expanded state at begin, preview and panel continuation, and closed the SIM card from its expansion callback.

The previous 0.3.13 fix only added Cellular's narrow window fallback; it did not touch these state gates.

## Local changes

- `Shared/LocalCleanStatusCCPolicy.h`: expanded is no longer a presentation rejection; kind, feature, unlocked, attached, not-presenting and no-conflicting-picker gates remain.
- `Sources/LocalCleanStatusControlCenter.m`: both direct and narrow-window Wi-Fi/BT recognizers remain; expansion updates state and rebinds but no longer closes the active list; list continuation no longer rejects expanded layout.
- `Cellular/LCSCellularEntryPolicy.h`: unknown, collapsed and expanded are valid observed states; invalid enum values still fail. Owned gesture and local safety gates remain required.
- `Cellular/LCSCellularHooks.m`: removes only expansion-state rejection from actual begin/preview/panel continuation; forwards native expansion and does not close an active SIM card. A bounded `expansionOverlayActive` flag retains a card while the cellular child view is temporarily hidden by the six-control transition, but lock, foreground, feature, controller and panel identity checks remain.
- Tests update the real C truth tables and add unified source/runtime-model contracts.

No system expander is blocked and no native foreign gesture decision is rewritten.

## Risks / not verified

This is not real-device proof. UIKit hit testing, exact gesture arbitration, whether the six-control page appears before/after the plugin presentation, short tap/cancel behavior and visual overlap remain unverified. A card may overlap the system six-control page; this candidate deliberately keeps the system expansion action rather than suppressing it. CI/build/install/device validation require separate gates.

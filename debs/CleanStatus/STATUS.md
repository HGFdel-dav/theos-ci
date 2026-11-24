# CleanStatus 0.3.14 — LOCAL candidate, unified compact/expanded overlays

## Authorization / stage

User approved local implementation and verification after installing 0.3.13 and reporting opposite state behavior: Wi-Fi/Bluetooth long press works compact but not after six-control expansion; Cellular works only after six-control expansion then return. Push, CI, package, installation, device writes, SIM actions, respring and restart remain unauthorized.

Base: published 0.3.13 source ZIP, 157 files. Frozen manifest: `docs/BASELINE-0314-UNIFIED-EXPANSION.json`.

## Scope

Unify long-press presentation across compact/expanded/unknown valid layouts for Wi-Fi, Bluetooth and Cellular. Keep native short taps, feature/unlock/visibility/presentation/conflict gates, SIM service/helper/card, DataSwitch, persistence and foreign gesture decisions. Do not suppress the native six-control expansion.

Wi-Fi/Bluetooth no longer auto-close an active list on expansion and their continuation no longer rejects expanded layout. Cellular no longer rejects unknown/expanded valid state and no longer closes its card on expansion; a bounded overlay-retention flag covers the child view disappearing during the expansion transition.

## Local checks

Production cellular gate: 50 C checks. Expansion trace contract: 59 + 3 mutation rejects. CC policy: 658 assertions. Unified expansion contract: 14. Core invariants 476; cellular 6291/167; UI 40; path 173; path model 37; panel 10; verifier 46/11/198. Two changed Obj-C translation units parse with iOS15.5 arm64e `clang -fsyntax-only -Werror`. No UIKit runtime or device validation.

## Risks

Not a proven fix. The card may visually overlap the system six-control page; real gesture ordering, hit testing, short tap/cancel, AMFI/loading and true user acceptance require a later CI/package/install/device gate.

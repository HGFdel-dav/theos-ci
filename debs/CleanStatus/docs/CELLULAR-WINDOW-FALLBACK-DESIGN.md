# CleanStatus 0.3.13 — cellular entry: narrow window fallback

Scope: local candidate only. No push, CI, package, install, device write, SIM action, respin.

## Why this narrow change

- 0.3.12 user observation: the SIM card does open sometimes but often does not
  (video `video_D4411D23.mp4`, creation 2026-11-23T15:23:46Z). The saved 128-entry
  diagnostics ring around that recording shows three sustained successes
  (present sim-manager at 23:23:22.545 / 24.914 plus an earlier one), but it does
  not contain a failed long press, so the failing branch is not proven.
- Known code gap (verified by reading both sources, not a guess about the system):
  the Wi‑Fi module in this same product binds its long press to the native round
  button **and** attaches a second long press to the hosting window, which only
  starts when (a) the native button is not direct-touchable, and (b) the touch
  point lies inside the button's bounds. The cellular entry had neither: it
  refused to bind at all when `LCSDirectTouch(button)` was false
  (`button-not-direct-touch`), and it had no fallback.
- Therefore a cellular long press on a button/ancestor that does not accept
  direct touch could not work at all. This candidate closes exactly that gap.

## What changes

1. Binding no longer treats "not direct-touchable" as fatal. Visibility, window
   identity, controller ownership, tap contract (no TouchDown/TouchDownRepeat
   action), and ownership checks are unchanged.
2. When the native button is not direct-touchable, one additional
   `UILongPressGestureRecognizer` (0.45 s, 10 pt) is attached to the hosting
   window. It accepts a touch only if:
   - the button is still in the bound window and visible,
   - the feature is enabled and no SIM card is already presented,
   - the button is still not direct-touchable,
   - the touch point is inside the button bounds (same inset rule as the existing
     optional preview path).
   `cancelsTouchesInView = NO`, so it can never swallow a short tap.
3. The direct recognizer is unchanged and now additionally requires
   `LCSDirectTouch(button)` in its begin gate; the fallback is refused when direct
   touch works again (`fallback-not-needed`). Both share one delegate, one target,
   and the existing expansion gate (`collapsed` only, no unknown/expanded).
4. Pure production predicate `LCSCellularWindowFallbackAllows` in
   `LCSCellularEntryPolicy.h` encodes the four conditions; it is executed by
   `tests/cellular/expansion_gate_test.c` including negative cases.
5. unbind/feature-off/lock/foreground-loss path detaches both recognizers.

## Unchanged behaviour

- Native short tap = system ON/OFF; stock `buttonTapped:`/`_toggleState` untouched.
- The long press still only opens the existing `LCSCellularSIMController`.
- Wi‑Fi / Bluetooth modules, DataSwitch module, SIM service, helper,
  entitlements, panel/card, persistence and icon sources are byte-identical to
  0.3.12 (checked by hash in the source contracts).
- No guessed system recognizer is blocked; `shouldBeRequiredToFailBy` keeps the
  exact non-pan rule from 0.3.11/0.3.12. The round-button hook still forwards the
  original result for every foreign gesture exactly once.

## Risks / not verified

- **Historical caution:** the 0.3.4 crash fix removed a UIKit subclass plus
  delegate forwarding plus a whole-window fallback in one change. The crash was
  in UIKit's `_shouldReceiveTouch:` forwarding path, not proven to be caused by
  the window recognizer itself. This candidate re-introduces only the narrow,
  region-checked window recognizer of the shape already used by the Wi‑Fi module
  in this package; no subclass, no forwarding, no `setOwner:`. Still unproven on
  device.
- The 0.3.12 "already-expanded at 23:23:15.279" rejection is untouched: if the
  module state is stale/expanded, the plugin still refuses. This candidate does
  not claim the six-control page will be skipped.
- If the native button never becomes direct-touchable and touch mapping is
  unusual, the fallback region test may still miss; only a device trace can tell
  (`bound-window-fallback`, `begin-fallback-eligible`, `press fallback-not-needed`).
- UIKit arbitration, real hit-testing, loading/AMFI acceptance and short-tap
  behaviour still require later, separately authorized build/install/device work.

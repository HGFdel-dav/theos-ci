# CleanStatus 0.3.13 — LOCAL candidate, cellular narrow window fallback

## Authorization / stage

User approved local implementation and verification of a fix after reporting that
the 0.3.12 SIM card opens only intermittently ("又可以了，只是经常按出不来",
"有时候不出来"). Push, CI, packaging, installation, device writes, SIM
operations, respring and restart remain unauthorized. This stage produced no iOS
machine code and no package.

Base: published 0.3.12 source ZIP, 155 files,
SHA256 `b5c9e0a9304545c4bda6f2d8f6c0e10e4d6d107b3d60389fef56fefd93fde88b`.
Frozen hashes / allowed scope: `docs/BASELINE-0313-WINDOW-FALLBACK.json`.

## Evidence used

- `video_D4411D23.mp4` (20.248 s, creation 2026-11-23T15:23:46Z): the card is
  shown; the recording also contains later Wi‑Fi panel interaction, so it is not
  one continuous cellular long press.
- Device read-only: `com.local.cleanstatus 0.3.12 iphoneos-arm64e`, no SpringBoard
  crash reports. The 128-event ring kept three successes
  (`present sim-manager`), no failed press, and predates/overlaps the recording
  only partially — the failing branch is **not** identified by logs.
- Source comparison (same package): Wi‑Fi binds a direct press **and** a
  region-limited window press used only when the button is not direct-touchable;
  cellular refused binding outright in that case.

## Scope of change (local only)

1. `Cellular/LCSCellularHooks.m`: binding tolerates a non-direct-touchable button;
   attaches exactly one extra long press to the hosting window, accepted only
   inside the button bounds, only while the button is visible, the feature is on,
   no card is presented and direct touch is unavailable. `cancelsTouchesInView=NO`.
   Direct recognizer additionally requires direct touch; both use the same
   delegate/target/expansion gate; unbind detaches both.
2. `Cellular/LCSCellularEntryPolicy.h`: pure predicate
   `LCSCellularWindowFallbackAllows` (using/!direct/visible/hitRegion).
3. Version 0.3.13; tests and docs updated; new design doc
   `docs/CELLULAR-WINDOW-FALLBACK-DESIGN.md`.
4. Everything else (Wi‑Fi/Bluetooth/DataSwitch modules, SIM service, helper,
   entitlements, panel/card, persistence, icons) byte-identical to 0.3.12.

## Known limits / risks

- Not a proven fix for the intermittent failure or for the six-control page.
  The 0.3.12 rule that refuses while the module reports `expanded` is unchanged;
  a stale/expanded state still yields no plugin card.
- The 0.3.4 crash previously removed a subclass + forwarding + whole-window
  fallback together; this adds back only a narrow region-checked window
  recognizer shaped like the existing Wi‑Fi one. No subclass/forwarding/setOwner.
  Real hit-testing and UIKit arbitration remain unverified.
- Short tap (system ON/OFF), cancel, lock, foreground loss and device acceptance
  still need separately authorized build/install/device validation.

# CleanStatus 0.3.15 — publication candidate: first binding / fallback correction

## Authorization / stage

User separately approved the corrected local implementation and has now explicitly
approved pushing this exact 0.3.15 candidate, running dedicated CI and auditing
its package. Installation, device access, SIM actions, respring and restart remain
unauthorized. The rejected pan draft remains on HOLD. No production changes are
introduced by this publication step; CI build/package results are pending here.

Base: published .14 commit `19d2a73f2da19181cc2c2eefe650938c0e76aaf5`, exact 160-file
source ZIP `ee1f88002a80274f8e8701817a1de466b9899ec0948dc53a83621e10ca8c921e`.
Scope manifest: `docs/BASELINE-0315-ENTRY-BINDING-FALLBACK.json`.

## Confirmed defects / scope

Previously collected .14 evidence: first load was followed by button-not-visible
and first binding only after native expanded. Exact reason for initial invisibility
is not identified. Two real fallback calls invert a directTouch argument already
inverted by the helper, contradicting the action guard. No pan winner is proven.

Only production change: `Cellular/LCSCellularHooks.m`. Passive preparation on a
unique identified button is separated from active visible/owned/unlocked usage;
window lifecycle synchronizes one fallback without replacing a valid direct
recognizer; trailing layout retry is retained; receive/begin pass raw directTouch;
actual action rechecks entryReady; route and delayed-outcome diagnostics are
separate from gesture-inventory budget. .14 Wi-Fi/BT files and all unrelated
business/storage/UI are frozen; pan and expanded lifetime methods are hash-pinned.

## Checks / verification boundary

Local stage complete; user separately approved this push/CI/package audit.
CI is pending at this publication commit; no native/device result is claimed yet.
All 20 recorded command exits match expectations; the native environment guard
returns 77 on Alpine by design, not an executed Foundation test.

Host C runs actual qualification expressions with modeled inputs: 264,102 checks
and four compiled call-site mutations rejected. Existing core/CC/state/entry/path/
UI/verifier tests are rerun. Native Foundation fake-object fixture: nine groups
prepared, syntax-only on Alpine; native assertions and UIKit runtime NOT executed.
See `../evidence/` and `../LOCAL-RESULT.md` for final exits and hashes.

## Risks / next gate

Not a demonstrated on-device fix. Compact hit-target/proxy selection, actual
gesture order, short-tap delivery, movement/OS cancellation, visual overlap,
injection and AMFI acceptance remain unverified. No zero-six-control-frame promise.
Next: complete authorized CI/package audit, then ask separately for installation;
respring and reboot each require later approval.

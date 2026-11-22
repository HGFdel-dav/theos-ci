# CleanStatus 0.3.6 — local cellular behavior repair candidate

## Confirmed baseline

Device readback: `com.local.cleanstatus` 0.3.5 arm64e installed; `simManager`, `dataSwitch`, and diagnostics were enabled. User reports pressing the stock cellular button produces no SIM manager and the independent data module has no usable SIM rows. The uploaded screenshot explicitly reports subscription-read failure. SpringBoard status logs at 13:53 showed two registered, ready SIMs and a live data connection; they prove cellular service exists, not that CleanStatus can access it. Diagnostics were last written at 11:46 and predate the latest interaction, so they cannot identify the new failing branch.

The 0.3.5 release only changed the version from 0.3.4; the cellular implementation was identical. Earlier safety-mode IPS records are not current evidence for these two failures.

## Local-only changes

The data service now prefers the same `SBTelephonyManager.sharedTelephonyManagerCreatingIfNecessary:` → `coreTelephonyClient` path found in the supplied DataSwitch source, after checking selector signatures, with direct `CoreTelephonyClient` as fallback. It logs only client source and coarse failure categories: no client, ABI mismatch, system read error, missing/empty subscription list, selection error, or successful list. No phone number, ICCID, UUID, carrier or raw error is logged.

The stock-button long-press binding no longer refuses to attach merely because a system gesture exists under the button. The stock short-tap action is not replaced; buttons with touch-down side effects still fail closed. Binding, press and presentation failures are recorded with bounded, deduplicated reason slugs. Presentation uses the window's current top controller, while preserving feature, lock, visibility, identity and foreground-close gates.

The independent 0.3.5 snapshot is `docs/BASELINE-035-RUNTIME.json` (140 files, commit `f8d808b9694e314b360ee2be9659a7ae9840ccd6`). Only the cellular service, gesture hook, related tests/checks, version fields and this status file may differ. UI/card design, module registration, helper, entitlements, RootHide paths, animation code, old status-bar controls and stock short toggle behavior remain protected.

## Verification state

- Regression checks passed: 0.3.5 freeze/scope and gesture assertions 296; cellular policy 6,291; cellular source/preservation 161; general source invariants 449; card layout 1,248; UI scope 284; path reuse 281; panel routing 10.
- Fixed iOS 15.5 SDK `-fsyntax-only` passed separately for `Cellular/LCSCellularService.m`, `Cellular/LCSCellularHooks.m`, the service fixture and the data-module service namespace. Source parsing generated no machine code.
- Apple Foundation service fixture did not execute on Alpine. The full batched SDK parser exceeded its time limit; its storage-fixture parser requires `THEOS`, so that batch is not counted as passed. No DEB, CI, injection/loading or device interaction test was run.

User authorized pushing this 0.3.6 candidate and running its dedicated GitHub CI build only. The release branch is `cleanstatus-0.3.6-cellular-fix-20261122`, based on 0.3.5 commit `f8d808b9694e314b360ee2be9659a7ae9840ccd6`. Installation, SIM operation, device writes, logout and restart remain unauthorized. Device remains on 0.3.5; neither reported function is yet proven fixed on-device.

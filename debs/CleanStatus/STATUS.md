# CleanStatus 0.3.7 — local cellular long-press rebind candidate

## Confirmed baseline

Device readback: `com.local.cleanstatus` 0.3.5 arm64e installed; `simManager`, `dataSwitch`, and diagnostics were enabled. User reports pressing the stock cellular button produces no SIM manager and the independent data module has no usable SIM rows. The uploaded screenshot explicitly reports subscription-read failure. SpringBoard status logs at 13:53 showed two registered, ready SIMs and a live data connection; they prove cellular service exists, not that CleanStatus can access it. Diagnostics were last written at 11:46 and predate the latest interaction, so they cannot identify the new failing branch.

The 0.3.5 release only changed the version from 0.3.4; the cellular implementation was identical. Earlier safety-mode IPS records are not current evidence for these two failures.

## Local-only changes

The data service now prefers the same `SBTelephonyManager.sharedTelephonyManagerCreatingIfNecessary:` → `coreTelephonyClient` path found in the supplied DataSwitch source, after checking selector signatures, with direct `CoreTelephonyClient` as fallback. It logs only client source and coarse failure categories: no client, ABI mismatch, system read error, missing/empty subscription list, selection error, or successful list. No phone number, ICCID, UUID, carrier or raw error is logged.

The stock-button long-press binding no longer refuses to attach merely because a system gesture exists under the button. The stock short-tap action is not replaced; buttons with touch-down side effects still fail closed. Binding, press and presentation failures are recorded with bounded, deduplicated reason slugs. Presentation uses the window's current top controller, while preserving feature, lock, visibility, identity and foreground-close gates.

The cellular long-press retry change starts from published 0.3.6 commit `869ddd0737f0c878322ef4ab9b2015632f952b7f`, frozen in `docs/BASELINE-036-RUNTIME.json`. Only `Cellular/LCSCellularHooks.m`, its two source-test/check files, version fields and this status record are intended to differ. The data-service repair, data module, short-toggle action, SIM helper and entitlements remain byte-identical to 0.3.6.

## Target symptom and evidence

Device 0.3.6 diagnostics logged `binding/button-not-visible` at 18:02:01, then no later bind or present event. The visibility predicate rejects a button or ancestor that is hidden or has alpha below 0.01. In 0.3.6 binding ran after view load/appearance and a few fixed startup delays; no controller layout callback rechecked visibility after later layout changes.

## Local change

The controller forwards `viewDidLayoutSubviews`, then schedules a main-queue rebind if the long-press target is absent or the button is still not visible. Calls are coalesced and throttled to at most one scan every 250 ms; an attached recognizer on a visible button returns immediately. The new layout hook is a required gate for enabling long press, and its signature failure is logged. Stock short-tap handling, touch-down safety, lock/OFF/resign cleanup and the published 0.3.6 data-service implementation remain unchanged.

## Verification state

- Layout-rebind source contract passed: 140 assertions; published 0.3.6 freeze checks pass with 127 unchanged files. Cellular policy: 6,291; cellular source/preservation: 159; general invariants: 452; UI scope: 40; card-layout C assertions: 1,248; path reuse: 281; panel routes: 10.
- Fixed iOS 15.5 arm64e SDK `-fsyntax-only` passed for `Cellular/LCSCellularHooks.m`; no machine code was generated.
- Apple Foundation cellular service fixtures cannot execute on this Alpine host. CI, DEB build/verification, injection/load and real device long-press interaction remain unverified.

The user authorized only local modification and verification for 0.3.7. Push/CI, installation, device writes, SIM operations, logout and restart are not included in that authorization. The device remains on 0.3.6; long-press rebind behavior is not yet proven.

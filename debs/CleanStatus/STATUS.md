# CleanStatus 0.3.3 — local reuse of the existing preference-path implementation

## Current authorization and result (2026-11-21)
- User instructed: use the way the existing source-available plugin already works. Scope is local correction only, NOT push/CI/device writes/install/respring/reboot.
- Installed 0.3.2 was confirmed in the preceding read-only investigation; user installed it independently. Its new cellular resolver rejected valid split program/data roots. The old animation code already handles the data root's `.jbroot` backlink.
- Cellular Settings now directly calls `local_cleanstatus_animationPreferencesPath()` and uses its separate sibling cellular filename. The unchanged old Animation/LocalCleanStatusAnimationPreferences.m is linked once into each additional image; Prefs already links it. No animation settings are read/written and its original build target is unchanged.
- Removed duplicate cellular root discovery and selected-root injection in tests. Existing atomic write/readback, migration, notifications, containment/no-follow checks and diagnostics are unchanged. Tool lookup follows the same old selected root's direct/backlink relationship.
- UI/card/header/glyphs, module implementation, hooks, subscription service, helper source/permissions and all old feature source files remain byte-identical to released 0.3.2. Changed scope: cellular path code, three build wires, candidate versions, tests and records.
- SDK15.5/arm64e/RootHide remains fixed. LOCAL source only; no iOS machine code or 0.3.3 package generated.
- New native fixtures execute the unchanged old root-discovery algorithm with only temporary filesystem prefixes substituted: split/flat roots, rejection/fallback/escape/stale cases, roundtrip and separate writer/reader processes. Native execution on this Linux host is an explicit SKIP, not a pass.
- Current details: docs/PATH-REUSE-LOCAL-RESULT.md. Push/CI and install require separate approval. The following 0.3.2 record is historical.

# Historical: CleanStatus 0.3.2 cellular local-candidate record

## User-confirmed behavior and authorization
- User explicitly approved local implementation after confirming: the existing iOS cellular-data CC button must keep its short-tap ON/OFF behavior; long press opens the SIM-line manager to enable/disable each SIM. Add one separate Control Center module for choosing which SIM is the default cellular-data line.
- Do not swap these two functions. Do not modify original status-bar, battery, animation, Wi-Fi/Bluetooth picker, or system-action behavior except the narrowly scoped new long-press integration on the stock cellular-data tile.
- Latest UI correction (2026-11-21): user explicitly requested BOTH the separate DataSwitch expansion and stock-button SIM-manager presentation match the uploaded video's compact dark material cards. The previous settings-sheet/table appearance was not accepted as video-aligned. This grant covers local UI changes and checks only; backend/identity/settings/hooks remain frozen.
- Authorized: local source modifications and portable/static tests only. Not authorized: device reads/writes, build/CI, commit/push, install, respring/reboot, or settings changes.

## Baseline
- Exact source archive from CleanStatus 0.3.1 commit `a1bf667d09fbdc48bf09beee04ef0c88800848c9`, SHA256 `2982f3ba0458da1a920da3cbe85d6540656398683f6b4a7f187c4cf9922606bb`; frozen manifest in `reference/BASELINE-031.json`.
- Target: iPhone 12 / iOS 15.5 / RootHide / arm64e / iPhoneOS15.5 SDK / version 0.3.2.
- Modules install under logical `/Library/ControlCenter/Bundles`; the new helper resolves beneath one cached current hidden root. Only when no RootHide root exists can the shared resolver fall back to `/var/jb`; it never writes preferences to real var or hard-codes a root UUID.
- The opaque uploaded CCSIMTool and all uploaded graphics are excluded from production. The candidate now contains its own source-built, identity-checked SIM tool and nine original PNG resources; reference packages remain outside the source tree.

## Research evidence
- Author SIMControl v1.0.1 source snapshot `SorenNing/SIMControl@4216d49e7c85c81fad663bfeef3f8d18945fa285`; package requires iOS >=16 and contains a precompiled CCSIMTool with special entitlements. Not a ready-made iOS 15.5 build.
- Author DataSwitch v1.0 source snapshot `SorenNing/DataSwitch@301e2510b2448a8781e0c08496b76641afbb471c`; package requires iOS >=16. Its private CoreTelephony APIs also appear in public iOS 15.3.1 Runtime-Headers commit `yuzhouheike/iOS15.3.1-Runtime-Headers@44a5b62df41f5f20d8af6dead3b426a7b401e118`: `CoreTelephonyClient` has `getCurrentDataSubscriptionContextSync:`, `getSubscriptionInfoWithError:`, `getSIMStatus:error:`, and `setActiveUserDataSelection:error:` (void); `CTXPCServiceSubscriptionContext` has slotID/UUID/userDataPreferred.
- Existing 0.3.1 CC tweak hooks `CCUIConnectivityWifiViewController` and Bluetooth equivalents; no cellular hook yet.
- Public iOS 15 EVOCenter bundle strings identify `CCUIConnectivityCellularDataViewController` as the stock module content controller; this is a candidate runtime class identity, not a proof of the device's exact loaded class/gesture lifecycle.
- iOS 15.3.1 headers show `CTCellularPlanManager` and `didSelectPlanItem:isEnable:`. SIMControl helper signatures/entitlement path remain privileged and not yet proven accepted on RootHide iOS 15.5.

## Implementation invariants and tests to add
- Preserve the native cellular button's existing short tap; the new long press must be recognized only on the uniquely matched stock cellular module round button, unlocked/visible/SpringBoard/iOS15, and must cancel the pending native tap only after the long-press threshold.
- UI reflects read-back system state; never claim a SIM or default-data switch succeeded based only on helper exit/request return. Revalidate selected subscription UUID immediately before data switch and reread afterwards.
- Two SIM slots must map by slotID and subscription UUID, never array order. Missing, ambiguous, absent, locked, stale or failed reads fail closed; no action when selection identity cannot be proven.
- EVERY SIM-off action requires confirmation. Telephony/storage work uses worker queues; UI and SpringBoard lock-state reads run on main. Cancellation/dismissal invalidates callbacks; requests already sent cannot be rolled back. UI completion is bounded, but a blocked synchronous private API may retain its worker/operation lock until the system call returns.
- Preserve existing control-center lock guard, modal ownership, QuickCC2 conflict behavior for Wi-Fi/Bluetooth, and original cell tap. Ordinary open, short tap, pan, cancellation, disabled feature, no SIM, dual-SIM, request failure and unavailable helper need explicit checks.
- Static/iSH tests are not iOS compilation, package verification, loader validation, or true-device functional evidence.

## Current phase — local source complete; NOT a built/tested release
- The missing UI, backend service and SIM-tool sources are now present. The two previous subagent completions contained no deliverable and were NOT counted as implementation or review success.
- Original behavior files remain byte-identical: 78 protected 0.3.1 files, including original Sources/Hooks/Shared/Animation and original SystemActions inputs. The remaining nine baseline files are limited to build wiring, preference entry/version, checking tools and this status record; original preference rows and target definitions are separately checked.
- BOTH UI surfaces now use compact 336x216-at-standard-text rounded cards: small top glyph, centered heading, two centered rows with green/gray observed-state badges. SIM management uses a centered dark-material modal with outside-tap/VoiceOver close; DataSwitch retains the native CC expanded platter with the same shared compact sizing. No settings table, UISwitch, checkmark accessory or Done button remains. Errors retain full messages/retry inside a scrollable card; header tap refreshes. No exact native/video parity is claimed before a device render.
- The UI-only manifest additionally protects 119 pre-existing candidate files byte-for-byte, including backend, helper, settings, original hooks and all old behavior. Row taps retain observed-state targets, confirmation, tokens and post-request readback.
- Passed: original core 5,252,881 checks; CC policy 658; cellular production-C policy 6,291; card layout/badges 1,248; UI structure/scope 155; cellular source/preservation 151; main source invariants 431; panel routing 10; path model 37; synthetic signature verification 46 + 10. These are not radio/runtime proofs.
- Fourteen new-source/conditional-build cases are parsed with clang `-fsyntax-only` against the actual fixed iPhoneOS15.5 SDK. No iOS object, dylib, executable or DEB was generated.
- Apple Foundation storage/migration and mock-service tests are supplied but not executed here (two explicit SKIPs). UIKit appearance, stock short-tap/long-press arbitration, current class image/ABI, CCSupport loading, helper signature/permissions/parent query, keybag+UI lock-state semantics and plan-manager `isSelected` versus actual radio state remain unverified on iOS15.5.
- No device access, real SIM changes, commit, push, CI, installation, respring or reboot occurred. Next gate is a separate user decision on push/CI; package verification must follow any successful build, and installation requires separate permission.
- Details: `docs/CELLULAR-LOCAL-RESULT.md`; local evidence is outside the shipping source tree in the candidate's `evidence/` directory.

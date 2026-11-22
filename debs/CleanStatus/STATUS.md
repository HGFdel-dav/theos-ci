# CleanStatus 0.3.8 — SIM-plan read through the entitled helper (local candidate)

## Confirmed baseline

The user recorded a 12.1 s video after installing 0.3.7 and reported that long press still failed. Device readback confirms `com.local.cleanstatus` 0.3.7 arm64e. The video shows that the “蜂窝管理” card does present, but it contains the message `系统未提供可核对的 SIM 计划，不能安全启停线路。` and two grey rows.

Diagnostics at 21:45:40–21:47:41 (device local time) record `layout-hook-installed`, `bound-direct-only`, three `sim-manager present` events and repeated `subscriptions-ready`. The 0.3.7 layout rebind therefore fixed the earlier `button-not-visible` failure: the card is now reachable. The remaining confirmed failure is an unavailable plan array in the SpringBoard service. The existing diagnostic does not distinguish a missing manager, ABI refusal or a nil query result. The reference's separate entitled helper and our helper's missing plan-info entitlement make permission/context separation the leading hypothesis, not a proven entitlement-denial trace.

The supplied SIMControl reference does not query plans from its SpringBoard module. It lists lines through `CoreTelephonyClient` (`getSubscriptionInfoWithError:`, `getSIMStatus:error:`, `copyLabel:error:`) and delegates plan changes to a separately signed helper carrying `com.apple.coretelephony.CTDataPlanDeviceInfo.allow`. Our previous helper had only `platform-application` and `com.apple.CommCenter.fine-grained`.

## Scope

This candidate starts from published 0.3.7 commit `7555934d4ac79280ff763c36769d85173d503041`, frozen in `docs/BASELINE-037-RUNTIME.json`. Only the service listing path, the helper plan identity, the helper entitlement, version fields, tests/tooling and this report are intended to differ. The data module, card layout, hooks, short tap and settings rows remain byte-identical to 0.3.7.

## Changes

- `Cellular/LCSCellularService.m`: SIM-manager listing now uses the same subscription context, SIM status and label path as the working data selector. No `CTCellularPlanManager` call remains in SpringBoard. A line with a unique subscription context and known SIM status is available; `kCTSIMSupportSIMStatusReady` is the enabled state. The data-switch branch keeps its existing behaviour.
- `LocalCleanStatusSIMTool/main.m`: the helper now accepts the subscription UUID, resolves each plan through `getSubscriptionContextUUIDforPlan:` (falling back to the plan’s `uuid`), keeps the `shouldDisplay`/`isInstalling`/`isSelected` safety checks, refreshes immediately before committing and still calls `didSelectPlanItem:isEnable:`. No slot index or ICCID is used.
- `LocalCleanStatusSIMTool/entitlements.plist`: adds only `com.apple.coretelephony.CTDataPlanDeviceInfo.allow = true`; the existing three fine-grained values are unchanged.
- `Cellular/LCSCellularService.m` helper wait: logs a bounded stage slug (`helper-usage`, `helper-identity`, `helper-plan-api`, `helper-gate`, `helper-request`, `helper-unusable`, `helper-plan-changed`, `helper-failed`) on a non-zero helper exit. Identity, ICCID and carrier text are never logged.
- Version 0.3.8 in `control`, both bundle plists and the version checks; tests and verifier expectations updated to the 0.3.7 baseline.

## Verification state

- SIM-plan source contract: 150 checks, including exact 0.3.7 data read/write branch hashes; published 0.3.7 frozen files 129 unchanged.
- Cellular policy: 6,291 assertions; cellular source/preservation: 160; general invariants: 455; UI scope: 40; card-layout C: 1,248; path reuse: 171; panel routes: 10.
- Verifier synthetic tests: 46 + 11 precise-entitlement + 198 DER checks; path model 37.
- Initial fixed iOS 15.5 arm64e SDK syntax-only checks passed for service and helper. After restoring the exact 0.3.7 data branches, the source contract and full host regression passed, but a final syntax-only service check exhausted local memory (`std::bad_alloc`) while reading SDK headers. That final parse is not counted as passed; the definitive final compilation is pending macOS CI. No iOS machine code was generated locally.
- Apple Foundation service fixtures cannot execute on this Alpine host. CI, DEB build/verification, injection/load, helper execution with the new entitlement, real long-press presentation and actual SIM enabling/disabling remain unverified.
- Known risk: a private entitlement may still be rejected even in the helper; the new helper stage log will identify the failing step. If a disabled line disappears from `getSubscriptionInfoWithError:`, this candidate cannot safely re-enable it without a slot-based fallback; that edge case has not been tested.

## Authorization

The user approved local implementation and subsequently authorized pushing this 0.3.8 candidate and running its dedicated GitHub CI. Installation, device writes, SIM operations, logout and restart remain unauthorized. The last verified phone version is 0.3.7. CI and package verification below are pending at the time of this source snapshot; final results belong in the separate release report.

# CleanStatus 0.3.12 — LOCAL candidate, known-collapsed entry + bounded trace

## Authorization / stage

User approved local implementation/verification and now separately approved pushing/building this exact 0.3.12 diagnostic candidate and auditing its package. Installation, device access/changes, SIM operations, respring and restart remain unauthorized. The preceding local stage generated no iOS machine code or package. The last read-only device confirmation was 0.3.11 arm64e on iPhone12/iOS15.5/RootHide, not a 0.3.12 runtime result. This remains a diagnostic candidate, not a proven direct-open fix; CI and package verification are pending at this commit.

Base: published 0.3.11 `1a36ffc4f9657841369348203c9c2bcdf9114f64`, exact 151-file source ZIP SHA256 `9dde4c7b7603629ac5d4d8ec7b6d3543b71a7182c403f52f3e44fa1e41630317`. Frozen hashes / allowed scope in `docs/BASELINE-0312-COLLAPSE-TRACE.json`.

## Current unresolved problem and evidence limits

Goal remains one long press from compact Control Center directly opening the existing SIM card without a six-control intermediate page. The user's 0.3.11 result did not meet this. Its trace proves its own round callback/gesture/card executed; the video includes several interactions and has the six-control page already visible before the logged cellular gesture. It cannot attribute the first expansion to that same contact, nor identify the winning system recognizer. No new SpringBoard crash was found in the prior read-only phase.

**Correction:** Apple `Preferring one gesture over another` explicitly shows `shouldBeRequiredToFailBy` YES makes OTHER wait for OWN failure (swipe delegate returning YES for pan: “Do not begin the pan until the swipe fails”). Earlier conversation/notes reversing that direction are incorrect. Candidate retains 0.3.11's non-pan rule. No claimed root cause from that line.

## Final local scope

- Only the exact cellular recognizer may begin when the native expansion callback has confirmed `Collapsed`; `Unknown`/`Expanded` fail closed for the plugin, native gestures keep their original decisions.
- No invented initial collapsed state at load/appearance. Last observed state survives unbind. Expansion callback is required (mask 47); action/panel/optional-preview paths recheck state.
- Bounded, sanitized touch/gesture/class/scope/native-round decision and transition traces; one read-only .7s weak/generation-guarded snapshot. New touches (including throttled touches), unbind/OFF/lock/foreground loss cannot run a stale snapshot. Existing diagnostic toggle/path/ring implementation unchanged.
- No guessed system-recognizer blocking or new dependency rule. Earlier `block-native` / `BlocksNativeBegin` / `ShouldYieldToOther` draft experiments removed before verification.
- Short-tap implementation, Wi-Fi/Bluetooth, main/animations, SIM service/helper/permissions/card, DataSwitch business code, persistence/resolver/notifications/settings/icons remain exact frozen bytes.

## Local checks

Entry arm64e iPhoneOS15.5 `clang -fsyntax-only` passed (no iOS machine code). Production C expansion predicate 29 checks and three compiled bad predicates rejected; original round policy 12 checks. Source contracts, full host regressions, UI/card/path/panel and verifier negatives passed locally; final counts/logs are recorded in outer `../evidence/` and `../LOCAL-RESULT.md`. Independent review delegation yielded no retrievable final report (job lookup returned job_not_found); no independent approval is claimed. Apple Foundation service is SKIP on Alpine, not claimed as runtime success.

## Important expected effect / risks

This is **not a proven direct-open fix**. Until UIKit actually reports a collapsed transition, an initial unknown-state long press can fall through to the native six-control page. The previously available SIM card long press inside the expanded six-control page is intentionally disabled by the approved collapsed-only gate. If that callback never reports collapsed, no plugin card will open: diagnostics are intended to distinguish this case, not to hide it. Limited snapshots may omit the real system expander; class name alone is not expander identity. Short-tap/cancel/native competition, loading/AMFI/device acceptance and zero-six-control-frame behavior still require future separately authorized build/install/device validation.

Full design and official sources: `docs/CELLULAR-EXPANSION-TRACE-DESIGN.md`. Historical 0.3.11 design/status claims in other archived documents do not override this record.

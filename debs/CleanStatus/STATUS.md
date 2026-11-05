# CleanStatus 0.1.0

As of 2026-11-04 (Asia/Shanghai).

## Phase and authorization
- User approved the 14-feature scope and explicitly authorized local implementation and checks.
- Local project: /var/minis/shared/CleanStatus; created from ios-roothide-tweak-forge generator.
- Target: iPhone 12 / A14 / iOS 15.5 / RootHide / arm64e; iPhoneOS15.5.sdk only.
- Package: com.local.cleanstatus, version 0.1.0; class prefix LocalCleanStatus.
- NOT authorized: commit, push, CI dispatch, package installation/uninstallation, preference changes on device, respring/reboot.

## Scope
11 independent status icon visibility controls: airplane, alarm, Bluetooth, Siri, CarPlay, Focus, location, rotation lock, cellular signal, VPN, Wi-Fi.
3 battery features: inline percentage modern appearance, hide charging bolt, tap status battery to toggle Low Power Mode.
Chinese PreferenceLoader panel, master switch, Apply button. All switches default OFF. Only Apply publishes changes.
Only presentation is changed except the explicitly enabled battery-tap Low Power action. No CPU/temperature/network meter.

## Local implementation and checks
- Shared RootHide preference resolution is cached once through `jbroot()`; legacy `.jbroot-*`, `/var/jb`, and real-var candidates are migration/read-delete candidates only.
- Preference writes validate containment under the selected RootHide root before directory creation, write atomically, and publish only after success.
- Panel uses a real `PSListController`, inherited `_specifiers` caching, a serial storage queue, and baseline conflict detection.
- `tools/check.py`: PASS, core 272145 exhaustive checks and source invariants 140.
- `tools/test_paths.py`: PASS, 29 path/migration cases.
- `tools/test_verify.py`: PASS, 46 synthetic accept/reject cases.
- Plist parsing, `build.sh` shell syntax, source text/NUL audit, and source archive generation: PASS. Archive test contained 34 files and excluded build artifacts/secrets.
- Source archive test SHA256: `85971d9641b865f3aafe37635260a7307b67048ff57525540b55adff5946f93e`.

## Validation boundaries
The local checks do not prove Objective-C compilation, DEB payload/signature correctness, SpringBoard loading, or runtime behavior.
Pending: repository/branch/version approval, commit/push, GitHub CI compile, DEB payload and signature validation, device installation/loading, and 14-feature functional tests.
The workflow contains one long metadata-generation line; it passed YAML/text checks and is not a functional failure. Conflicts with other status bar tweaks remain possible. Missing runtime APIs must fail closed.

## Next gate
Local implementation and checks are complete. Ask for separate approval of repository/branch/version before commit, push, or CI.

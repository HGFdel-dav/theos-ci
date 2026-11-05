# CleanStatus 0.1.1 (local repair)

As of 2026-11-05 (Asia/Shanghai).

## Phase and authorization
- User authorized pushing and compiling version 0.1.1 using `GITHUB_TOKEN_QQ` in this conversation. Installation, preference changes, respring, and reboot are not included.
- Local project: /var/minis/shared/CleanStatus; last pushed source: `HGFdel-dav/theos-ci/debs/CleanStatus`.
- Target: iPhone 12 / A14 / iOS 15.5 / RootHide / arm64e; iPhoneOS15.5.sdk only.
- Package: com.local.cleanstatus, repair version 0.1.1; class prefix LocalCleanStatus.
- Version 0.1.1 is local only: not committed, pushed, or built by CI.
- Device package installation/uninstallation, preference changes on device, respring, and reboot remain unauthorized.

## Scope
11 independent status icon visibility controls: airplane, alarm, Bluetooth, Siri, CarPlay, Focus, location, rotation lock, cellular signal, VPN, Wi-Fi.
3 battery features: inline percentage modern appearance, hide charging bolt, tap status battery to toggle Low Power Mode.
Chinese PreferenceLoader panel, master switch, Apply button. All switches default OFF. Only Apply publishes changes.
Only presentation is changed except the explicitly enabled battery-tap Low Power action. No CPU/temperature/network meter.

## Version 0.1.1 local repair
- Root selection now starts from the same known-working `jbroot(@"/var/mobile")` mapping used by ParticleX, derives its parent, then accepts only a real `.jbroot-*` directory directly under `/var/mobile/Containers/Shared/AppGroup`.
- Writes remain restricted to the selected hidden root and checked before/after directory creation. If resolution fails, no write occurs; no real `/var` fallback was added.
- PreferenceLoader now references the original `CleanStatusIcon` asset. The template icon file `icon@2x.png` is removed; the new 120x120 (60pt @2x) signal/battery/status icon is generated from `tools/draw_icon.py`.
- Package, panel, metadata, and verifier version: 0.1.1.
- `tools/check.py`: PASS, 272145 core cases and 144 source invariants.
- `tools/test_paths.py`: PASS, 32 cases including mapped-mobile-to-hidden-root and rejection of `/var/mobile` or ordinary directories.
- `tools/test_verify.py`: PASS, 46 synthetic accept/reject cases.
- All plist files parse; shell syntax passes; template icon absence and custom icon dimensions are asserted.

## Previous release (0.1.0)
- Repository: `HGFdel-dav/theos-ci`; branch: `cleanstatus-0.1.0`.
- Commit: `d39888556021e220bb5b7418be7f755cad6bb0d6`; GitHub Actions run #97 `41969854056` succeeded.
- Previous DEB SHA256: `19d47414cc948960813dc2445253851d99a04b172cb4f189701c9ebeb4c0a9fa`.
- Previous source zip SHA256: `4e00b49be02be4197d98d63343834dcb3fa216cbf8a107f29dce799ba421d562`.

## Validation boundaries and next gate
Version 0.1.1 has not been compiled or device-tested at this snapshot. The path tests model the mapping; they do not execute RootHide `jbroot()` on-device. Push/CI is authorized for `HGFdel-dav/theos-ci`, new branch `cleanstatus-0.1.1`, version `0.1.1`. Installation, device preference changes, respring, and reboot require separate authorization.

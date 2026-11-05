# CleanStatus 0.1.2 (local repair)

As of 2026-11-05 (Asia/Shanghai).

## Phase and authorization
- User authorized pushing and compiling version 0.1.2 using `GITHUB_TOKEN_QQ` in this conversation. Installation, preference changes, respring, and reboot are not included.
- Local project: /var/minis/shared/CleanStatus; pushed project path: `HGFdel-dav/theos-ci/CleanStatus`.
- Target: iPhone 12 / A14 / iOS 15.5 / RootHide / arm64e; iPhoneOS15.5.sdk only.
- Package: com.local.cleanstatus, repair version 0.1.2; author/maintainer Niubiprass; class prefix LocalCleanStatus.
- Final commit: `d1da06706828d4dfe1c1c9138191be166add84f6` on new branch `cleanstatus-0.1.2`; GitHub Actions run #1 `41983645879` succeeded.
- Device package installation/uninstallation, preference changes on device, respring, and reboot remain unauthorized.

## Scope
11 independent status icon visibility controls: airplane, alarm, Bluetooth, Siri, CarPlay, Focus, location, rotation lock, cellular signal, VPN, Wi-Fi.
3 battery features: inline percentage modern appearance, hide charging bolt, tap status battery to toggle Low Power Mode.
Chinese PreferenceLoader panel, master switch, Apply button. All switches default OFF. Only Apply publishes changes.
Only presentation is changed except the explicitly enabled battery-tap Low Power action. No CPU/temperature/network meter.

## Previous release (0.1.1)
- Workflow: dedicated `.github/workflows/build-cleanstatus.yml`, project at root `CleanStatus/`; it does not trigger the shared `debs/**` build.
- CI host checks, fixed Theos + iPhoneOS15.5 SDK, RootHide arm64e compile, in-workflow strict DEB verification, dSYM retention, and artifact upload all passed.
- DEB SHA256: `21df7630e1d673b6863dc83040bbade4890e46f23424db97858844775b7703ec`.
- Source zip SHA256: `3694a9e591a617b3a2848015825d46817420335a1c128541fd7e31c224497c6e`.
- Independent local verification repeated: 9 payload files, all under RootHide `Library/`, no maintainer scripts; both binaries arm64e with 15.5 SDK/minOS and SHA-1/SHA-256 code pages; empty entitlements.
- 0.1.1 used the single `CleanStatusIcon@2x.png`; 0.1.2 replaces it with the 29/58/87 set.
- Delivery directory: `/var/minis/attachments/CleanStatus-0.1.1-ci-41983645879/`.

## Version 0.1.2 source repair (current, not yet pushed)
- Root selection first tries the `jbroot(@"/var/mobile")` mapping. If that is identity/invalid, it scans `/var/mobile/Containers/Shared/AppGroup/.jbroot-*` and ranks roots: contains this dylib → contains MobileSubstrate → contains usr/lib; ties use newest mtime. Result is cached once per process; `/var/jb` is the last resort.
- Writes remain restricted to the selected hidden root and checked before/after directory creation. If resolution fails, no write occurs; no real `/var` fallback was added.
- PreferenceLoader icon uses the 29/58/87 standard set (`icon.png`, `icon@2x.png`, `icon@3x.png`), RGBA with transparent ~22% corners, rendered from one master in `tools/draw_icon.py`. The template icon and the old single 120px asset are removed.
- Package, panel, metadata, and verifier version: 0.1.2.
- `tools/check.py`: PASS, 272145 core cases and 148 source invariants.
- `tools/test_paths.py`: PASS, 35 cases including identity-jbroot fallback to priority scan and `/var/jb` last resort.
- `tools/test_verify.py`: PASS, 46 synthetic accept/reject cases.
- All plist files parse; shell syntax passes; template icon absence and custom icon dimensions are asserted.

## Previous release (0.1.0)
- Repository: `HGFdel-dav/theos-ci`; branch: `cleanstatus-0.1.0`.
- Commit: `d39888556021e220bb5b7418be7f755cad6bb0d6`; GitHub Actions run #97 `41969854056` succeeded.
- Previous DEB SHA256: `19d47414cc948960813dc2445253851d99a04b172cb4f189701c9ebeb4c0a9fa`.
- Previous source zip SHA256: `4e00b49be02be4197d98d63343834dcb3fa216cbf8a107f29dce799ba421d562`.

## Validation boundaries and next gate
Compilation, CI DEB verification, independent DEB verification, payload review, and icon replacement passed.
Device installation/loading, `jbroot()` behavior in the real device environment, successful preference save, icon rendering in Settings, SpringBoard behavior, and the 14 features remain unverified. The next gate is installing 0.1.2 and tapping Apply; respring/reboot or device preference changes need separate authorization.

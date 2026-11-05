# CleanStatus 0.1.8 (release size trim)

As of 2026-11-05 (Asia/Shanghai).

## Phase and authorization
- User authorized pushing and compiling version 0.1.8 using `GITHUB_TOKEN_QQ` in this conversation. Installation, preference changes, respring, and reboot are not included.
- Local project: /var/minis/shared/CleanStatus; pushed project path: `HGFdel-dav/theos-ci/CleanStatus`.
- Target: iPhone 12 / A14 / iOS 15.5 / RootHide / arm64e; iPhoneOS15.5.sdk only.
- Package: com.local.cleanstatus, repair version 0.1.8; author/maintainer Niubiprass; class prefix LocalCleanStatus.
- Final commit: `bff7c7b26dcbbabfcce7696dc4ac61f2a7f3c61a` on branch `cleanstatus-0.1.8`; GitHub Actions run #7 `42007635624` succeeded.
- Device package installation/uninstallation, preference changes on device, respring, and reboot remain unauthorized.

## Scope
11 independent status icon visibility controls: airplane, alarm, Bluetooth, Siri, CarPlay, Focus, location, rotation lock, cellular signal, VPN, Wi-Fi.
3 battery features: inline percentage modern appearance, hide charging bolt, tap status battery to toggle Low Power Mode.
Chinese PreferenceLoader panel, master switch, Apply button. All switches default OFF. Only Apply publishes changes.
Only presentation is changed except the explicitly enabled battery-tap Low Power action. No CPU/temperature/network meter.

## Version 0.1.8 artifact verification
- DEB SHA256: `f2a4ad3d8266bb479b53d8b0f4063b6a885fc4d78067974b8c7c49d76c0d86f9`.
- DEB SHA256: `d30360fe3f1e2b1fb11c839255e15808de7e9032dad9f32614d0a523ea056931`.
- DEB SHA256: `54b6a73f71821dd470c4ee8a07277b0abddf5a8175ee5a8341f57e7bdfc9c9be`.
- DEB SHA256: `96b359a60a3ae389bb1d7ff5c307be7edce88dfb594cee5543f7fdd5c8718548`.
- 9 payload files, author Niubiprass, signatures and three icon sizes verified.
- DEB SHA256: `eebc534422e440c1efa4a687c210051ce73d14e68f7de11c709cca2e305c5506`.
- 9 payload files, author Niubiprass, signatures and three icon sizes verified.
- DEB SHA256: `d8ef5462cd7bccc9e82751eddade8f4379f58c10e927612dce9be8e6312a8840`.
- Source zip SHA256: `37ca21f134f6f3cecf884812b2b09db72262575d6b176671a0e480bcf3c33f6a`.
- 9 payload files, three icons 29/58/87 RGBA, author Niubiprass, signatures verified.
- Delivery directory: `/var/minis/attachments/CleanStatus-0.1.8-ci-41989768520/`.

## Previous release (0.1.1)
- Workflow: dedicated `.github/workflows/build-cleanstatus.yml`, project at root `CleanStatus/`; it does not trigger the shared `debs/**` build.
- CI host checks, fixed Theos + iPhoneOS15.5 SDK, RootHide arm64e compile, in-workflow strict DEB verification, dSYM retention, and artifact upload all passed.
- DEB SHA256: `21df7630e1d673b6863dc83040bbade4890e46f23424db97858844775b7703ec`.
- Source zip SHA256: `3694a9e591a617b3a2848015825d46817420335a1c128541fd7e31c224497c6e`.
- Independent local verification repeated: 9 payload files, all under RootHide `Library/`, no maintainer scripts; both binaries arm64e with 15.5 SDK/minOS and SHA-1/SHA-256 code pages; empty entitlements.
- 0.1.1 used the single `CleanStatusIcon@2x.png`; 0.1.8 replaces it with the 29/58/87 set.
- Delivery directory: `/var/minis/attachments/CleanStatus-0.1.1-ci-41983645879/`.

## Version 0.1.8 build and source repair
- Panel and tweak use one fixed logical preference path, `/var/mobile/Library/Preferences/com.local.cleanstatus.plist`; RootHide may redirect `/var/mobile` at the filesystem layer. No root probing and no `jbroot()` identity assumption.
- Migration candidates are deduplicated by canonical parent and inode; cleanup never deletes a path that is the same file as the target. This addresses the observed cycle where a successful write was then removed as a supposed old copy.
- Battery body and fill are solid `labelColor` (black light / white dark), not the gray native `bodyColor`; green charging, yellow low-power, red <=20%; text and bolt use contrasting ink.
- Quiet-mode icon is hidden by hooking `_UIStatusBarIndicatorQuietModeItem` `iconDisplayIdentifier` and `staticIconDisplayIdentifier`, matching Genesis.
- PreferenceLoader icon uses the 29/58/87 standard set (`icon.png`, `icon@2x.png`, `icon@3x.png`), RGBA with transparent ~22% corners, rendered from one master in `tools/draw_icon.py`. The template icon and the old single 120px asset are removed.
- Package, panel, metadata, and verifier version: 0.1.8; author/maintainer Niubiprass. Release builds use `-Os` and `-Wl,-S` to trim binary size.
- `tools/check.py`: PASS, 272145 core cases and 148 source invariants.
- `tools/test_paths.py`: PASS, 33 cases including `/` containment.
- `tools/test_verify.py`: PASS, 46 synthetic accept/reject cases.
- All plist files parse; shell syntax passes; template icon absence and custom icon dimensions are asserted.

## Previous release (0.1.0)
- Repository: `HGFdel-dav/theos-ci`; branch: `cleanstatus-0.1.0`.
- Commit: `d39888556021e220bb5b7418be7f755cad6bb0d6`; GitHub Actions run #97 `41969854056` succeeded.
- Previous DEB SHA256: `19d47414cc948960813dc2445253851d99a04b172cb4f189701c9ebeb4c0a9fa`.
- Previous source zip SHA256: `4e00b49be02be4197d98d63343834dcb3fa216cbf8a107f29dce799ba421d562`.

## Validation boundaries and next gate
Compilation, CI DEB verification, independent DEB verification, payload review, and icon replacement passed.
Device installation/loading, `jbroot()` behavior in the real device environment, successful preference save, icon rendering in Settings, SpringBoard behavior, and the 14 features remain unverified. The next gate is installing 0.1.8 and tapping Apply; respring/reboot or device preference changes need separate authorization.

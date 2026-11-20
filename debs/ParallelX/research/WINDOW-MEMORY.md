# Window memory — reference and integration evidence

## Scope and authority
User approved local work only: per-App normal split-window size + position, separate device/content orientations; all ordinary and clone split opens; same bundle's clone accounts share geometry. Default enabled; Settings switch and confirmed reset. No new push, CI, device installation, restart, respring or device write authorization.

## Baseline
- Actual source: `2f0d81540af3477ddad777174dddcb7ca1af8bbf` (clone0.92), archived without build outputs into this isolated candidate. `/tmp/ci-work` is unchanged.
- User previously installed clone0.92 and reported no problem. Last read traces had successful transactions (4.011s, 3.012s, 2.437s); these do not validate the new feature or every old path.
- Rollback DEB SHA256: `b389880031ccca3c9e9557a7992d60317c56e8496b7752e2233c484785ae99ed`.
- The legacy STATUS described clone0.9; it was historical, not the current state.

## Supplied reference (static only, never installed/executed)
ScreenCore 2.0.5 / `com.susudear.screencore`, supplied `shared-6F7F64B9.deb`, SHA256 `4081026da03c7b2b8f2c4ccef444aa2a26b389c740199c6eb7de2aa428dad0e5`.
- `SplitSettings.plist`: `splitRememberSizeAndPosition` defaults false; reset action `sc_resetRememberedSizeAndPosition`.
- Chinese text: 按应用分别记忆，原生与 16:9 共用正常布局. Reset text includes all Apps, clones, portrait and landscape.
- `SCFloatingSceneManager` relevant methods: reconcile `0x46490`, read `0x465fc`, save frame `0x46730`, save predicate `0x46890`, remember current `0x469a0`; getters/setters `SCPreferences{Get,Set}RememberedSplitFrameForTarget`.
- Static read/save methods pass the target + host/content landscape flags. The proprietary implementation is not copied or injected. Exact complete reference event ordering is not claimed from strings alone.

## Native ParallelX interfaces (immutable vendor)
SHA256 `b1f4bd28bb6c6936be2b059140f1af38f4da25bb2eeb5c2380b9d0bf2a3c2ce6`.
Six method-table relative entries, selectors, method encodings and IMPs are byte-verified by `tests/fixtures/window-memory-alpha391-abi.json` and its test:
- `-[PXPanelEntry resizeHost:]` 0x410a4, `moveHost:` 0x42d2c: `v24@0:8@16`.
- `-[PXSceneBridge openApplication:inView:keyboardOverlay:completion:]` 0x65fc8: `v48@0:8@16@24@32@?40`.
- `layoutHost` 0x5e9d8 and `close` 0x66c44: `v16@0:8`.
- `-[PXHostViewController viewDidLayoutSubviews]` 0xce60: `v16@0:8`.
Native apply-resize (0x40d64) updates the inner hostCard.frame (setFrame at 0x40ff0), calls layoutIfNeeded, then bridge.layoutHost (0x41064). It does not resize the display-filling hostWindow. This is why the candidate finds the native PXHostCard ancestor of canvas and never KVC-reads Swift static fields or jumps into Swift functions.

## Settings API checked
Theos public headers consulted (read-only, no dependency update):
- https://github.com/theos/headers/blob/master/Preferences/PSSpecifier.h — `buttonAction` and preferenceSpecifierNamed.
- https://github.com/theos/headers/blob/master/Preferences/PSListController.h — inherited `_specifiers` and reloadSpecifiers.
The new controller is a true PSListController, reuses the existing injected Preferences image and root entry. Existing three resource icons remain byte-identical; no new plugin icon or bundle is created.

## Storage decision
Existing PXClonePrefs comments mention flock, but its current implementation actually writes `CXStore` through CFPreferences without a cross-process file lock. Therefore the new feature does NOT concurrently add geometry into CXStore or change the existing account store. It reuses the existing cached RootHide resolver, root/parent validation and atomic I/O in an isolated sibling document, protected by its own flock. No real-var/UUID hardcode is introduced. Both runtime and Settings compile the same store.

## Review corrections
Independent static review identified late first-load restore overriding user gestures and stale saves after orientation changes. Candidate now has an explicit pending-save barrier, preserves user ownership on first direction observation, binds gesture stamps to their orientation, and tests these production predicates including compiled broken variants. These were code-derived issues, not reported device reproductions.

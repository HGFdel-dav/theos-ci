# ParticleX app-deletion audit (read-only)

**Scope:** local iOS 15.5/A14 header references and `Sources/PXCAppDeletion.m`; no device/runtime mutation.

## Initial evidence

- `reference/SBHIconManager.h` declares all three methods:
  - `- (void)uninstallIcon:(id)icon;`
  - `- (void)uninstallIcon:(id)icon animate:(_Bool)animate;`
  - `- (void)uninstallIcon:(id)icon animate:(_Bool)animate completion:(CDUnknownBlockType)completion;`
- `reference/SBIcon.h` exposes uninstall state/alert text (`uninstallAlertTitle/body/ConfirmTitle/CancelTitle`) and `setUninstalled` / `completeUninstall`, but does not show the caller or ordering.
- `video-effect-review/headers/SBIconController.h` exposes `SBAlertItemsController` ownership/activation observer callbacks, but no uninstall method declaration or app-removal alert class in the currently located headers. `SBRemoveWidgetAlertItem.h` is widget-specific and is not evidence for app deletion.
- Therefore headers alone do **not** prove that `uninstallIcon:*` presents confirmation. Exact caller/order remains a runtime or SpringBoard-binary call-site question unless a public implementation/source reference is found.

## Current hook observations

`PXCAppDeletion.m` calls `PXCDelAnimate(icon)` **before** each original uninstall IMP and then forwards the original arguments unchanged. It does not present/dismiss/answer an alert and does not change uninstall state or view visibility. `PXCInstallHooks` marshals installation to main thread before calling this installer. Runtime confirmation boundary is still unproven.

## Must-check items

- Preserve one original invocation and exact ABI for each overload; do not assume all three are invoked in one deletion path.
- Add/retain an explicit main-thread guard at the visual-capture entry (and avoid off-main UIKit traversal); installation-on-main alone does not prove every caller thread.
- Hooking uninstall entry is a pre-original hook point, not proof of post-confirmation timing. If the method is reached only after confirmation, the effect is confirmation-gated; if it is also used to initiate/present removal, it is not.

# CleanStatus 0.3.4 — local SpringBoard gesture-crash mitigation candidate

## Scope and evidence

User authorized a **local-only fix** for safety mode. Installed 0.3.3 was confirmed; no package has been installed by the assistant. Two SpringBoard IPS reports (05:57:24 and 06:03:26) show main-thread SIGABRT in UIKit touch/gesture-recognizer collection and Objective-C forwarding; they do not include the thrown selector/reason or the CleanStatus image. Sanitized diagnostics record cellular-tile bindings at 05:57:17 and 05:57:50. This is strong temporal and code-path evidence, not proof of a unique missing selector. The earlier wxkb_plugin SIGQUIT has a launchd termination reason and a different stack, so is not asserted to be the SpringBoard root cause.

The candidate removes the custom long-press subclass, all custom UIGestureRecognizerDelegate callbacks, the CCUIRoundButton gesture hook and whole-window fallback. It tries one ordinary target/action UILongPressGestureRecognizer on the uniquely found stock cellular button only when the verified native short-tap contract is present, the button is in the expected controller/window, is directly touchable and no recognizer exists on it or any descendant. Otherwise it leaves the stock interaction alone and offers no long-press manager. It never sets the system recognizer's private `owner` property. Controller lifecycle forwarding remains; disappearance, lock, feature OFF, resignation and panel close detach/cancel the new recognizer and panel. The data module, SIM service/identity checks, helper, settings-path implementation, card UI and all prior feature files remain byte-identical.

A completed long press does cancel that button's touch sequence; short tap remains untouched before the recognition threshold. Whether the private CC tile really has the assumed action and whether SpringBoard loads/accepts this path remains unverified on-device.

## Local verification

- 174 crash-scope/source assertions; 446 main source invariants; original core 5,252,881; CC policy 658; cellular policy 6,291; card 1,248; path model 37; signature fixtures 46+10; DER fixtures 140.
- Fixed iPhoneOS15.5 SDK arm64e `-fsyntax-only`: 18 production/conditional cases + 4 native-fixture translation units. No machine code or package generated.
- The 0.3.3 baseline has 136 files. 128 remain byte-identical; only the gesture hook, test/check/protection/version/status paths changed. The UI, backend, shared-root implementation, helper and old feature code are exact baseline hashes.
- Apple Foundation runtime tests are SKIPPED on this Linux host. Static tests and source parsing do not demonstrate that SpringBoard safe mode is cleared.

Evidence and unified diff are under candidate `evidence/`. Uploaded IPS is outside `source/` and excluded from any source package.

No push/CI, install, device write, SIM operation, logout or reboot occurred. Next gate is separate approval to push/CI this exact candidate. Installation must be asked separately.

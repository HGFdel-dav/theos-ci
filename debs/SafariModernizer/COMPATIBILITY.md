# Compatibility rebuild scope

- Based on upstream SafariModernizer 1.0.1, commit `13aa4b1bf3053ab0a46504665b1dab79c8403d4a` (MIT).
- Preserve all upstream runtime features, webpage scripts, browser filter, per-site settings and cache paths.
- The delivered compatibility rebuild used `tweak/Tweak.x` with only a compile-time guard include; its delivered package remains unchanged.
- The rh2 follow-up changes only watchdog escalation: a detected module-scan/rewrite freeze advances the next-load site mode to at least 2 (Lighter), which skips the module loader.
- Build with Apple clang / Xcode 16.4, exactly iPhoneOS15.5.sdk, deployment target iOS 15.0, arm64e, native `roothide/theos` scheme.
- Do not disable PAC, falsify architecture metadata, repackage the old rootless binary, or claim that a changed SDK alone proves the crash fixed.
- Mach-O output must show authenticated `SMCSSHandler` class/metaclass ISA and superclass fields with the expected DA key/address discrimination. Package layout and CodeDirectory page hashes must also pass.

## What is NOT changed

No new panel, switch, animation, website feature, private Hook, settings migration mechanism or device-side helper is added. Original settings stay inside the host application's cache directory, not the real global Preferences directory.

## Validation boundaries

Source checks and synthetic verifier tests are not an iOS compile. A verified CI DEB is not proof of successful device loading or of every feature on every iOS 15.x point release.

The original package is already uninstalled. No reinstallation, respring or reboot is authorized in this phase.

## Official references

- https://github.com/iamjhe08/SafariModernizer/tree/1.0.1
- https://github.com/roothide/Developer
- https://github.com/roothide/theos
- https://github.com/roothide/Dopamine
- https://github.com/tealbathingsuit/ellekit
- https://github.com/apple-oss-distributions/objc4/blob/objc4-841.13/runtime/objc-runtime-new.h#L1874-L1903

The GitHub workflow is scoped to one independent branch and one project, with `contents: read`; it never commits packages to main.

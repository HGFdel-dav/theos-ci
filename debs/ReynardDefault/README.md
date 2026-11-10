# ReynardDefault

A jailbreak tweak that redirects Safari URL opens to [Reynard](https://github.com/minh-ton/reynard-browser), a Firefox-based browser for iOS.

When enabled, any link that would normally open in Safari is intercepted at the SpringBoard level and opened in Reynard instead.

## 1.5.38 plugin-only native click candidate

The package keeps the original SpringBoard Safari-to-Reynard behavior. Inside Reynard it keeps the GeckoView request hook for HTTP(S) Universal Links and adds a version-guarded native Gecko `OnLinkClick` hook for custom schemes. Both paths are in this one DEB; no WebExtension, XPI, profile extension write or signature preference change is included.

The native hook checks the Firefox 159 XUL UUID and exact `OnLinkClick` prologue. Its XUL slice is plain arm64 even in the arm64e app process, so the `nsIURI::GetSpec` vtable entry is called without arm64e PAC authentication; the helper has an arm64e assembly regression check. The hook handles only top-level, foreground, user-triggered clicks, and leaves downloads, POST/header requests or mismatched XUL builds to Gecko. HTTP(S) uses the GeckoView request callback; accepted Universal Links are handled once, otherwise the original URL continues in Gecko. Custom schemes are handed off from the native link-click entry; known Telegram `tg:` action spellings get only the missing `//`, preserving the rest of the address bytes.

This remains a static/CI candidate until device acceptance.

## Features

- **Safari redirect** — hooks `FBSystemServiceOpenApplicationRequest` in SpringBoard to swap the bundle identifier
- **Reynard click handoff** — native Gecko link-click route; no separate extension required.
- **Settings toggles** — master switch plus one switch per direction, via PreferenceLoader
- **Control Centre toggle** — quick toggle for the Safari redirect via CCSupport module

## Icon

The Settings row icon uses Reynard's app icon from
[minh-ton/reynard-browser](https://github.com/minh-ton/reynard-browser)
(`browser/Reynard/Resources/Assets.xcassets/AppIcon.appiconset/icon.png`),
rendered at 29/58/87 px with the rounded mask baked in. The Settings →
Control Center icon (116/174 px) is the upstream artwork and is left alone.
The Control Centre toggle itself uses the fox alone as a plain template
silhouette, so the tile keeps the system look instead of an orange block.

## Requirements

- A jailbroken iOS device — supports **rootless** (Dopamine/Roothide) and **rootful** (unc0ver, palera1n rootful)
- [Reynard](https://github.com/minh-ton/reynard-browser) browser installed
- [CCSupport](https://moreinfo.thebigboss.org/moreinfo/depiction.php?file=ccsupportDp) (for Control Centre toggle)
- [PreferenceLoader](https://github.com/PoomSmart/PreferenceLoader) (for Settings pane)

## Building

Requires [Theos](https://theos.dev/).

```bash
export THEOS=~/theos
cd ReynardDefault
make rootless   # Dopamine / Roothide
make rootful    # unc0ver / palera1n rootful
make both       # builds both variants side-by-side
```

Builds land in `packages/` as `*_iphoneos-arm64.deb` (rootless) and `*_iphoneos-arm.deb` (rootful). Rootless debs installed via Sileo on Roothide are auto-patched; manual installs need the Roothide Patcher app first.

## Historical upstream environments (not 1.5.34 acceptance)

The following table came from the original Safari-redirect project. It is not evidence that this handoff update has been tested on these devices.

| Device | iOS | Jailbreak | Variant | Status |
|--------|-----|-----------|---------|--------|
| iPhone 14 Pro Max | 16.3.1 | Dopamine (Roothide) | rootless (`iphoneos-arm64`) | Working |
| iPhone 7 | 15.7.7 | Dopamine | rootless (`iphoneos-arm64`) | Working |
| iPhone 7 Plus | 14.8.1 | Taurine 1.1.7-3 | rootful (`iphoneos-arm`) | Working |

Tweak injection via ElleKit (rootless) or substrate (rootful) on arm64 / arm64e.

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.

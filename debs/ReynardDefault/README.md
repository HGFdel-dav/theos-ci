# ReynardDefault

A jailbreak tweak that redirects Safari URL opens to [Reynard](https://github.com/minh-ton/reynard-browser), a Firefox-based browser for iOS.

When enabled, any link that would normally open in Safari is intercepted at the SpringBoard level and opened in Reynard instead.

## 1.5.34 repair candidate

This update targets user-clicked links only. The signed content script transports custom-scheme clicks with a single encoded fragment; native code validates a real Gecko gesture, request identity and freshness before opening. Known Telegram `tg:resolve` forms are normalized to `tg://resolve` without losing query or fragment data. Other schemes keep their documented opaque/hierarchical form.

HTTP(S) remains an original browser navigation. Only an eligible user-gesture PreNavigation attempts `universalLinksOnly`; failure returns `false` to Gecko so the same request continues. History, load-error and arbitrary extension-message events never launch apps. Page-wide metadata is not substituted for unrelated links.

The extension is installed through Gecko's signed-package interface. This candidate no longer forges `extensions.json`, overrides signature preferences, broadcasts installation commands, or reloads tabs automatically. An installation confirmation may be displayed by Reynard. A small onInstalled event page refreshes the click handler in existing HTTP(S) tabs; it does not navigate or open apps.

Validation status: source/host tests and package provenance are separate from device acceptance. Third-party app target screens, platform confirmation dialogs and asynchronous scripted/Android intent links require runtime compatibility; no blanket guarantee of Safari-equivalent behavior is claimed.

## Features

- **Safari redirect** — hooks `FBSystemServiceOpenApplicationRequest` in SpringBoard to swap the bundle identifier
- **External link handoff** — inside Reynard, non-web links (`tg://`, `mailto:`, `tel:`, …) are handed to the matching app instead of dying in the browser. Hooks `-[GeckoEventDispatcherWrapper dispatchToSwift:message:callback:]` in `Frameworks/GeckoView.framework`, answers "handled" to Gecko and calls `UIApplication.openURL:`; web schemes stay in the browser
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

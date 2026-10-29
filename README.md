# theos-ci

Jailbreak tweaks and packages for iOS, built on GitHub Actions.

## Projects

| Project | Description |
| --- | --- |
| [SplitX](debs/SplitX) | Arc handle and split-window panel with Crane container switching. |
| [Twin](debs/Twin) | Split-screen suite on the ParallelX engine: arc wake, containers, window-size memory. |
| [ParallelX](debs/ParallelX) | Split screen with a built-in Crane container menu. |
| [ChoicyWhitelist](debs/ChoicyWhitelist) | Choicy whitelist mode: no injection by default, allow per app. |
| [RoutePilot](debs/RoutePilot) | Per-app VPN routing between direct and proxy. |
| [MiniSight](debs/MiniSight) | Shows when Minis is driving the device. |
| [TIMCleanKit](debs/TIMCleanKit) | Frosted popup, editable packet range and keywords for TIM. |
| [insulation](debs/insulation) | Thermal-control override with on/off/low/max modes. |
| [DYYY](debs/DYYY) | Upstream tweak build, for study only. |

## Layout

```
debs/       Theos projects, one directory per tweak
packages/   built .deb files and dylibs (arm64 / arm64e)
tools/      helper scripts
.github/    CI workflows
```

## Building

CI runs Theos with `iPhoneOS15.5.sdk` on macOS. Every package is produced twice: `iphoneos-arm64` (rootless, `/var/jb`) and `iphoneos-arm64e` (RootHide, `/Library`). Push changes under `debs/**` and the workflow builds both.

## Notes

Compiled binaries are unsigned test builds. Install on a device with a matching jailbreak; a build success is not a runtime guarantee.

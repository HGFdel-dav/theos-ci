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
| [CleanStatus](debs/CleanStatus) | Status-bar and Control Center customization. |
| [MinisAgentDaemon](debs/MinisAgentDaemon) | Minis companion daemon. |
| [ReynardDefault](debs/ReynardDefault) | Theos tweak project. |
| [ShanLianRenew](debs/ShanLianRenew) | ShanLian renewal helper tweak. |
| [TIMCleanKit](debs/TIMCleanKit) | Frosted popup, editable packet range and keywords for TIM. |
| [insulation](debs/insulation) | Thermal-control override with on/off/low/max modes. |
| [DYYY](debs/DYYY) | Upstream tweak build, for study only. |
| [insulation-rh3](debs/insulation-rh3) | Reference/baseline material; no Makefile, not included in the batch build. |

## Layout

```
debs/<project>/   Tweak source, Makefile, tests and package inputs
packages/         CI-collected .deb files plus selected dylib/plist outputs
tools/            Shared build, packaging and analysis helpers
tests/            Repository-level regression/policy checks
.github/workflows/ Dedicated and batch CI workflows
```

`packages/` is intentionally retained and committed by the existing batch workflow. It is a convenient published build snapshot, not the canonical source. The canonical per-project source remains under `debs/<project>/`.

Theos creates `debs/<project>/.theos/` during builds. Compiler objects, module caches, stamps and other scratch are generated data; do not use `.theos/` as a source or release directory. This cleanup removes confirmed cache/intermediate files from tracking and ignores future `.theos` contents. Some legacy `.theos/_` package-stage snapshots remain tracked for compatibility and are deliberately left untouched pending a separate review.

See [the repository guide](documentation/REPOSITORY-STRUCTURE.md) for source/output boundaries and [the CI workflow map](documentation/CI-WORKFLOWS.md) for build entry points.


## Building

The main `build-theos.yml` workflow runs on pushes under `debs/**` and on manual dispatch. It builds `iphoneos-arm64` (rootless, `/var/jb`) and `iphoneos-arm64e` (RootHide) with `iPhoneOS15.5.sdk`; the workflow collects its batch outputs in `packages/` and uploads a run artifact. Dedicated workflows handle selected projects and packaging/analysis tasks. See [the CI workflow map](documentation/CI-WORKFLOWS.md) before changing trigger paths or output handling.

## Notes

Compiled packages are unsigned test builds. Install only on a matching jailbreak; a successful build does not guarantee runtime behavior. `packages/` is the current convenience snapshot committed by CI. Older versions and full run artifacts are not interchangeable; keep their provenance when moving release outputs elsewhere.

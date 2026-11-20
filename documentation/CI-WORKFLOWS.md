# CI workflow map

This is a navigation index for `.github/workflows/`. Each YAML file remains the source of truth for exact triggers, matrices, and artifacts. Check the actual workflow before changing paths.

| Workflow | Main role | Trigger summary |
| --- | --- | --- |
| [`build-theos.yml`](../.github/workflows/build-theos.yml) | Batch Theos build for projects in `debs/`; rootless arm64 and RootHide arm64e | Push under `debs/**`, or manual dispatch |
| [`build-cleanstatus.yml`](../.github/workflows/build-cleanstatus.yml) | Dedicated CleanStatus build | CleanStatus/workflow changes, or manual dispatch |
| [`build-native.yml`](../.github/workflows/build-native.yml) | ReynardDefault native checks/build | ReynardDefault/workflow changes, or manual dispatch |
| [`build-insulation-rh3.yml`](../.github/workflows/build-insulation-rh3.yml) | Insulation rh3 baseline/matrix build | `insulation-0.1.38.1-rh6` branch push, or manual dispatch |
| [`build-shanlian.yml`](../.github/workflows/build-shanlian.yml) | ShanLianRenew macOS Theos build | Manual dispatch |
| [`build-shanlian-linux.yml`](../.github/workflows/build-shanlian-linux.yml) | ShanLianRenew Linux build | Manual dispatch |
| [`build-callassist-unlock.yml`](../.github/workflows/build-callassist-unlock.yml) | CallAssist unlock package | `patches/CallAssistUnlock/**` push, or manual dispatch |
| [`build-debsbatch-ipa.yml`](../.github/workflows/build-debsbatch-ipa.yml) | DebsBatch IPA/dylib packaging | `tools/DebsBatchLib/**` or workflow changes, or manual dispatch |
| [`build-rea-analysis.yml`](../.github/workflows/build-rea-analysis.yml) | REA analysis evidence | `tools/DebsBatchLib/**` or workflow changes, or manual dispatch |
| [`ping.yml`](../.github/workflows/ping.yml) | Small manual runner check | Manual dispatch |

## Output guidance

- The batch workflow currently uploads `packages/*.deb` as a run artifact and commits collected files under `packages/` to `main`. Changing that behavior is a release-flow change, not just a layout cleanup.
- Dedicated workflows have their own artifact naming/retention; inspect their YAML rather than assuming all outputs are committed to `packages/`.
- `insulation-rh3/` currently has no Makefile, so the generic batch loop skips it; the dedicated workflow invokes its own build script.
- Build success is CI evidence, not proof of installation or runtime behavior.

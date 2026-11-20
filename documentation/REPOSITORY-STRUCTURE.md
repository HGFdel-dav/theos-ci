# Repository structure and storage boundaries

This repository is a multi-project Theos CI workspace, not a vendored Theos toolchain checkout. Keep authoritative sources separate from generated build state.

| Path | Purpose | Handling |
| --- | --- | --- |
| `debs/<project>/` | Per-tweak source, Makefile, controls, layout inputs, project tests | Canonical source; preserve. |
| `debs/<project>/.theos/` | Theos build scratch, object files, module caches and package staging | Do not add new build state. Confirmed compiler/cache files are no longer tracked; future `.theos` contents are ignored. Existing tracked `.theos/_` package-stage snapshots remain during this cleanup. |
| `packages/` | CI-collected `.deb` and selected dylib/plist convenience outputs | The existing batch workflow writes these back to `main`; retained. Not a substitute for source or per-run provenance. |
| `tools/` | Shared packaging, inspection and CI helper code | Preserve as source. Some subdirectories have dedicated workflows. |
| `tests/` | Repository-level policy and host checks | Preserve; run checks whose declared inputs exist. |
| `.github/workflows/` | Dedicated and batch workflows | Preserve; use the workflow map before changing triggers. |
| `src/` | Shared source used by selected projects | Preserve. |

At this revision there are 14 directories under `debs/`; 13 have a `Makefile`. `insulation-rh3/` is reference/baseline material without a Makefile and is not picked up by the generic batch loop. Check the relevant workflow before adding, moving or renaming a project.

A project may keep source beside its Makefile, in nested source folders, or in `layout/`. Do not move projects solely for visual symmetry: workflow scripts and package paths can depend on current locations.

## Generated build data

The first cleanup removes tracked files only from confirmed generated areas: `.theos/obj/`, `.theos/module-cache/`, `.theos/external/` stamps, `.theos/build_session`, `.theos/fakeroot`, `.theos/last_package`, and relevant `.stamp` files. These are recreated by Theos. The `.theos/_` package-stage directories may contain localized resources, helper binaries, dylibs/plists or staged metadata and remain tracked until separately reviewed.

This is a current-tip cleanup, not a Git history rewrite. Old commits still contain their historical files. History rewriting is out of scope because it changes commit IDs and affects clones and collaborators.

## CI storage behavior

The batch workflow builds multiple packages, copies `.deb` outputs into `packages/`, commits those outputs to `main`, and uploads a run artifact. Dedicated workflows separately build selected projects. Treat packages as versioned deliverables, not scratch; preserve run/tag/commit provenance when moving artifacts elsewhere.

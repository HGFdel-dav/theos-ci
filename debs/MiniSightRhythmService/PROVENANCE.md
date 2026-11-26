# Provenance / SPDX

- AudioSnapshotServer2: https://github.com/ryannair05/AudioSnapshotServer2 at
  `20d26f5061fa7db132da5148e18d814947f1905e`, MIT, Copyright 2024 Ryan Nair.
  `LICENSE` is retained verbatim. Immutable upstream evidence lives in the local
  review's `source/capture/upstream` (23 files); this is not a runtime dependency.
- BeatDetektor: https://github.com/cjcliffe/beatdetektor at
  `85a662048e4a906ddb40a511f9fa2ab7a7712c80`, MIT,
  Copyright (c) 2009 Charles J. Cliffe. Full MIT notices are inside BOTH original
  `shared/vendor/BeatDetektor/BeatDetektor.{h,cpp}` files, copied without edits.
  Header SHA256: `aca16316f11a8d53d75cf34bd56fece6775b7b2e1bb1ecb3b4e5e84998d84418`.
  Source SHA256: `b7c5f347941baf4e09314ae1f4ddbd380e8c5f89a36ee642aed4733a17db9d6b`.
  Pin attribution uses previously fetched/reviewed local evidence, not a new
  independent network fetch. Do not rewrite vendor bytes to silence warnings.
- `shared/MiniSightRhythmAnalyzer.{h,cpp}` and shared frame/wire are exact imports
  from the current paired App/plugin cores. Analyzer runs TWO unchanged vendor
  tempo windows; source reuses the previously reviewed local wrapper, not a
  new claimed general music detector. Original upstream vendor remains separate
  from MiniSight-authored wrapper and protocol extensions.
- Local MiniSight changes: rhythm bridge and epoch/sample-clock, loopback feature
  protocol, build pairing, bounded receive client, format admission, and offline
  test/build scripts. New local source is SPDX-License-Identifier: MIT; original
  ASS2/BeatDetektor notices are retained. CaptureEngine/Tweak/FeatureServer differ
  from ASS2; see MANIFEST.json and the review's baseline for exact local hashes.

`MANIFEST.json` enumerates every source path/hash/size except itself (count field)
plus seven shared-import hashes. For this plugin-only .58 adapter, run
`scripts/check_manifest.py` (read-only), or `--refresh` to rewrite ONLY this
manifest after reviewed build/test/document changes. The exact path set is
checked as well as hashes; counts are generated. Historical `sync_source.py`
belongs to the original capture review: do NOT run it to overwrite this plugin
adapter or the frozen capture/App trees. No git submodule, network retrieval,
app-relative include, or sibling App tree is required to build the service.

## .58 local build/test helpers

- `check_manifest.py`, `test_single_source.py`, `test_single_support.py`: local
  MiniSight-authored offline helpers, MIT (SPDX in each file). No third-party
  runtime code or network dependency was introduced.
- `macho_audit.py`: adapted from the existing local .57 static Mach-O auditor,
  local MiniSight MIT changes; uses Python standard-library struct/hashlib only.
  It checks integrity, not Apple trust or successful on-device loading.
- Aggregate integration follows the already cached official RootHide Theos
  `958fea4f779943505b15b93c88bb4db8d97b346d` master/aggregate.mk rules; no Theos
  source is copied into this project or modified. Its existing upstream license
  continues to apply in the externally pinned CI checkout.

# MiniSightRhythmService — local source candidate, not a live-tested release

Default `SOURCE` is strictly capture=0/transport=0 (no constructor/hooks compiled).
`LIVE` explicitly requires capture=1/transport=1; partial combinations fail in
make AND compilation. This local change does NOT enable a released build, run
capture, open a socket, invoke a constructor, install a service or change a user
setting. A LIVE source build is not authorization to load it.

## Independent plugin-tree build

The complete mirrored subtree is `source/plugin/debs/MiniSightRhythmService`.
`shared/` includes byte-identical Analyzer/Frame/Wire/ReceivePolicy and the
unmodified MIT BeatDetektor sources from both cores. No sibling App checkout is
needed. `RHYTHM_CORE ?= shared` may be overridden only by an audited exact copy.
`PROVENANCE.md`, full upstream MIT notices and `MANIFEST.json` travel with it.
The runtime capture sources remain byte-identical to the .57 baseline. This
.58 plugin-only build/test adapter must not be synced over the frozen capture
review tree. The manifest reports the exact current files and unchanged shared
imports. Neither original `/tmp` checkout nor old release is touched.

Pure source checks, from the standalone service directory:

```
python3 scripts/check_manifest.py
make -f build/Pair.mk source-check
make -f build/Pair.mk live-check
python3 scripts/test_release_pair.py
python3 scripts/test_single_source.py
```

The historical `sync_source.py` belongs to the frozen capture review; do not
run it over this plugin-only packaging adapter. `check_manifest.py --refresh`
changes only the local manifest, not shared imports or runtime bytes. Native
Apple/Foundation/SDK gates remain required in future CI; missing Apple locally
must reject strict mode, never be described as runtime PASS.

```
# Historical broader host/SDK runner (NOT part of this local-only review):
# python3 scripts/check_local.py --output /absolute/review/output
```

Future **separately approved CI runner only** (not authorized or run locally):

```
CI=true MINISIGHT_RHYTHM_CI_BUILD_APPROVED=1 make -f build/Pair.mk live-package MINISIGHT_PACKAGE_OUTPUT=/absolute/new/output
```

MiniSight 0.8.58 uses standard pinned Theos `aggregate.mk`: the top-level
MiniSight project recurses `all`, `clean`, `internal-stage` into this independent
service subproject, then makes exactly ONE DEB using MiniSight's control. The
historical Pair.mk/package_pair.py filenames are entry compatibility, NOT a pair
of packages. No binary concatenation, old-DEB unpack/repack, or service deletion.
Both targets stay separate: SpringBoard/MiniSight min15.0 and
mediaserverd/MiniSightRhythmService min15.5, SDK15.5, same per-file warning limits.
RootHide is arm64e; rootless is arm64. No sibling App checkout is needed.

The CI entry runs the source contract, aggregate clean/package, requires exactly
one fresh DEB, and statically audits BOTH dylibs (ABI, minOS, SDK, every signed
code page), BOTH exact filters (binary/XML plist encodings), paths, control,
archive modes/owner encoding and absence of extra payload/maintainer scripts.
Only then does it atomically publish one DEB, SINGLE-ARTIFACT.json and one-line
SHA256SUMS. Existing output, member failure, missing/corrupt half, cancellation,
or extra DEB rejects publication. SOURCE0 can never use this LIVE-only entry.
No install, respring, launchctl or target-IP recipe was added. Main control
Provides (=0.1.0), Conflicts and Replaces the old independent service; normal
mobilesubstrate and firmware>=15.5 dependencies remain. Installer migration,
RootHide owner-name resolution and audio behavior are NOT device-validated.

## Input safety and limits

Filter ONLY mediaserverd. Only Apple manufacturer + mixer type + MultiChannelMixer
subtype, **output scope (`kAudioUnitScope_Output`, value2), bus0** are admitted.
Global scope0 is NOT an audio output scope. No RemoteIO/VoiceIO, mic/input tap,
all-app injection, network audio source, compressed/integer/big-endian/unknown
flags or bus1. Only packed float32 mono/interleaved stereo/non-interleaved stereo,
8..192kHz, one frame/packet, <=4096-frame quantum. Unsupported devices fail closed;
real mediaserverd format/component availability on iOS15.5 is NOT yet verified.

The original render executes first and its status is preserved; missing/failing
original never copies. Render uses existing lock-free epoch/generation/gate and
bounded ring writes only: no allocation/locks/API queries/FFT/sockets/ObjC/logs.
Control queue owns lease expiry/source transitions/drain/quarantine/FFT/analyzer.
Zero subscribers disables copying immediately; expired 15s client leases disable
at the next bounded control tick. Current render may finish before stop drains.
Lifecycle rollback/error/quarantine contracts are retained.

Source is **systemmix**, including alerts; cannot prove NetEase-only or app-isolated
music. No microphone permission or recording API is used. Ordinary silence,
steady tone and noise must not become valid beats. Bare digital-zero-separated
pulses remain a known unsupported FAIL; not all music is supported.

UDP binds and sends ONLY IPv4 127.0.0.1:44334. MiniSight asks only for mask4,
numerical rhythm/energy/sample-clock features, bounded session/sequence and leases;
no PCM/music metadata leaves the service, and nothing goes to an external host.
ASS2-compatible waveform/spectrum masks remain available to legacy local clients;
loopback is a locality check, NOT cryptographic peer authentication.

2048 genuine PCM samples -> 1024 pre-band FFT bins (Nyquist omitted) -> production
wrapper/two unchanged BeatDetektor windows, only on serial control queue. No LRC,
position clock or timer-generated beat. Fresh sample counts, not poll time, advance
the sample clock. Drop/stale/silence/session/epoch resets invalidate old beat state.
Receiver latest-value mailbox consumes <=16 packets per tick, clears at <=0.35s
no-data freshness and unsubscribes/closes on disabled scene. App/Plugin client
seek API accepts explicit measured positions only; pass NAN for missing evidence.

Parent still owns daily versus music modes, independent music-setting/owner
separation, stable track generation and real-position call-site wiring. Existing
roamPace/roamingPaused vetoes were intentionally NOT blindly deleted while
mayPerformMusicMotion still depends on mayRoam. Missing lyrics do not gate input.
No claim is made about phone beat alignment, CPU/power, route transitions, actual
musical accuracy, runtime loading or paired DEB validity until separately tested.

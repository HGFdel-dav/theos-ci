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
The capture tree is canonical; sync with `scripts/sync_source.py --workspace D`
and verify with `--check`. The manifest reports exact current counts (not stale
46/47-file claims). Neither original `/tmp` checkout nor release is touched.

Pure source checks, from the standalone service directory:

```
make -f build/Pair.mk source-check
make -f build/Pair.mk live-check
python3 scripts/check_local.py --output /absolute/review/output
```

Future **separately approved CI runner only**, after parent finalizes the service
control/package/version and App macro/PBX wiring (not changed here):

```
CI=true MINISIGHT_RHYTHM_CI_BUILD_APPROVED=1 make -f build/Pair.mk live-package RHYTHM_PAIR_OUTPUT=/absolute/new/output
```

That target selects BOTH flags=1 for service and plugin, runs the source contract,
cleans both before build, and requires a fresh service DEB AND plugin DEB with
RootHide `iphoneos-arm64e` payload/filter plus SHA256 manifest. It rejects an
existing output directory and the current placeholder service control; no
continue-on-error or old-artifact fallback. Workflows are intentionally unchanged.
A future CI must require this target + both uploaded artifacts; plugin-only CI
success is NOT a live-rhythm success. Service stays SDK15.5/arm64e/FINALPACKAGE=1,
hidden/dead-stripped, bounded warnings, no broad Wno-error. It has no install,
respring, launchctl or target-IP recipe. Default source-only packaging is inert.

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

# MiniSightRhythmService — LOCAL SOURCE CANDIDATE ONLY

ASS2 MIT source at 20d26f5061fa7db132da5148e18d814947f1905e, isolated from the original repository and installed service. This snapshot is approved for default-OFF CI/link/package verification only; no install or runtime validation. MINISIGHT_ENABLE_RHYTHM_CAPTURE defaults to0: constructors AND hook implementations are preprocessor-excluded. Makefile does not override it. An explicit future flag1 build would have a mediaserverd constructor; do NOT load without separately approved device work.

Standalone RootHide/arm64e candidate, SDK and deployment target 15.5; only MiniSightRhythmService.plist (mediaserverd). No target IP, install hooks or respring rules.

UDP loopback 44334; mask4 appends exactly68 LE bytes after the legacy28-byte prefix and any requested waveform/spectrum arrays. Legacy masks1/2/3 keep exact sizes and prefix behavior. New rhythm masks use the rhythm continuity epoch and unsmoothed RMS/peak in the prefix to agree with the appended frame and shared decoder. The original AudioUnit stream epoch remains in FeatureFrame.streamEpoch. Rhythm epochs additionally change on any capture drop/stale/silence/reset; sampleTime resets at that boundary and counts only freshly drained samples/rate, never timer time.

1024 true pre-band FFT magnitudes (only the separately stored Nyquist bin is omitted) from2048 PCM samples feed the sibling C ABI analyzer, on the serial control queue only. No padded64-band spectra and no BeatDetektor in render. Only a requested rhythm bit creates/calls the analyzer. A poll without fresh audio never calls it and never replays a Beat. A newly allocated rhythm session resets rhythm-only warmup (not old waveform/spectrum state); a same-session lease renewal does not. No PCM or metadata is sent. The source is a system mix (including alerts), NOT isolated application music.

Wrapper/BeatDetektor compilation sources stay under ../MiniSight; frame+wire headers are exact snapshots of the parent's shared headers. See the complete audit, SHA256 provenance and offline test results in ../../../capture-adapter/.

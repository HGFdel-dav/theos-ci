# clone1.13: cold-start split-open retry

## Evidence (handed over 2026-10-28)
- Target app cold launch from the home screen: 3/3 succeeded on the first tap.
- Same app cold launch through the split path: attempts 1 and 2 were killed, attempt 3 succeeded.
- Not memory: load 1.9, Minis 423M, no JetsamEvent at the failure times.
- Every tap has a matching `.ips`: `termination namespace=FRONTBOARD, code=0x8BADF00D`,
  `WatchdogEvent=scene-create` or `process-launch`, `ProcessVisibility: Background`,
  allowance only 0.2–1.9 s while the app itself needs about 5 s to launch.
- Two failure stacks: DYYY+0x4341c (return site inside `%orig` of
  `didFinishLaunchingWithOptions`, `initTargetClassNames` not reached yet), and one with
  no DYYY frames at all (all inside AwemeCore class lookups). DYYY adds launch cost but
  is not the only variable.
- Stock `vendor/ParallelX.dylib` has no retry/重试 string, only
  `hasSceneForApplication:` / `sceneForBundleID:`. Stock has no fallback either.
- `CXOpenAppHook` in 1.11 only logs the trace and forwards to `CXOrigOpenApp`; the real
  bundle path has no wait and no retry.

## Change (new file `pxclone/CXColdRetry.inc`, included by `CXHook.m`)
- Armed from `CXOpenInSplit` only, after `CXOpenInSplitImpl` returns.
- Cold start only: returns immediately when `CXAppRunning` is true. Running/hot opens are
  byte-for-byte the old path.
- Skipped while the account chooser is on screen (`CXShowingChooser`) or while a system
  route still waits for a selection (`CXSystemRoutePending`), so nothing stacks on an
  unfinished container switch.
- After the request: poll every 0.5 s for 5 s. Re-issue the same split request on process
  death (`SBApplicationProcessState.pid` drops to 0) or when no scene appeared in the
  whole window. Two retries, three attempts total, 0.4 s spacing. Never unbounded.
- Re-issue goes through `CXOpenInSplitImpl` under `CXInternalOpen = YES`, so signature
  checks, bypass marking and logs match the first request, and PX's own routing cannot
  re-open a chooser.
- Success = `prepareWindowForBundleID:` arrived: `CXCancelColdRetry` stops the polls
  immediately (also for the real bundle behind a virtual entry).
- Failure converges: attempt 3 with no scene, or process still gone after attempt 3,
  logs `[retry] … giving up` and removes the state.
- Re-entrancy: a second tap during a live sequence logs
  `already retrying … ignoring duplicate request` and does not arm a second sequence;
  the retry state is keyed by bundle.
- No fullscreen fallback. `applicationActivated:` is still not used as an entry point.

## Untouched
- `CXPromptContainerThenOpen`, `CXPromptForURL`, `CXSystemRouting.inc` and
  `CXChooserController`: no edits. The payment / account-selection source is unchanged;
  retry only attaches at the shared split entry and self-skips while a chooser or route
  is pending.
- Container switching (`CXCraneBridge`), the virtual-item path and `CXPrepareWindow`
  behaviour other than the cancel call.

## Verification
- `tests/test_cold_retry.py`: 14 host-side guards (cold-only, chooser/route skip,
  duplicate tap, death retry cap, no-scene timeout cap, success cancel, bounded windows,
  single include, no fullscreen fallback, internal-open re-issue). All pass.
- `tests/test_system_routing.py`: 6 existing guards still pass.
- Host-side only. No iOS compile or device run for this build yet.

## Logs to look for on device
- `[retry] <bundle> cold start: monitoring for 5s (max 3 attempts)`
- `[retry] <bundle> attempt N poll M: elapsed … pid … hasScene …`
- `[retry] <bundle> attempt N: process died (was …)` / `timeout (5s no scene), retrying`
- `[retry] <bundle> cancelled (prepareWindow arrived …)` / `exhausted attempts, giving up`

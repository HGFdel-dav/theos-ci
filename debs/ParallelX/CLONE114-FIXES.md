# clone1.14: cold-start split-open retry (hook point corrected)

## 1.13 on device: retried zero times
- Device had 1.13 installed (`dpkg -s` Version `0.1.0~alpha377+clone1.13`, dylib 374896 B).
  Resprung at 01:27:01, hooks all `installed=1`.
- runtime.log shared-345B9A4A: 抖音 opens at 01:27:15, 01:28:02, 01:28:08, 01:28:22,
  01:28:35, 01:28:47, 01:29:23, 01:29:41 — **zero `[retry]` lines and zero `[open]` lines**
  in the whole window (last `[open]` was 00:22, before the install).
- Crash reports match the four failed taps: 01:27:36, 01:28:17, 01:28:21, 01:28:30, all
  `0x8BADF00D` `WatchdogEvent: scene-create`, `ProcessVisibility: Background`,
  `exhausted CPU time allowance of 0.95 seconds`. The 01:28:35 tap produced
  `prepareWindow` at 01:28:38 and worked.
- Also one WeChat crash at 01:30:41.

## Why 1.13 never armed
Retry was armed only from `CXOpenInSplit`, which is reached for virtual clone entries and
URL/system routes. A plain app icon in the PX panel does not go through it: the panel
calls PX's own action path, which ends in `openApplication:inView:keyboardOverlay:completion:`
without any of our functions in between. 抖音 has no clone containers, so every tap took
that plain path.

## Fix
- Arm from the `openApplication:` hook as well — it is the one funnel every split open
  uses (plain icons, clone items, URL routes).
- Armed after the original call is forwarded, never before, so the request really is in
  flight; the plain-icon branch also checks the argument is an NSString first.
- The clone branch arms after the container switch, with the resolved real bundle.
- `CXOpenInSplit` keeps its arm (earliest point, still needed for URL routes when PX
  refuses to open at all). Duplicate arms collapse into one sequence.
- Guard order unchanged in `CXStartColdRetryIfNeeded`: hot start, chooser on screen,
  system route pending, then the duplicate check.

## Everything else unchanged from 1.13
- Poll 0.5 s, window 5 s, two retries (three attempts), 0.4 s spacing, success requires
  scene **and** live pid, death or no scene re-issues, `prepareWindow` cancels, failure
  logs and stops, no fullscreen fallback.
- Re-issue goes through `CXOpenInSplitImpl` under `CXInternalOpen = YES`.
- Payment / chooser / container-switch source untouched.

## Verification
- `tests/test_cold_retry.py`: 15 guards, all pass (two new: all four arm points exist;
  the `openApplication:` arm happens after forwarding and is type-guarded).
- `tests/test_system_routing.py`: 6 guards pass.
- Host-side only; no iOS compile or device run for this build yet.

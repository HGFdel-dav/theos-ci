# clone1.11: account chooser / SpringBoard crash regression

## Evidence (2026-10-27)
- User report: WeChat opened before choosing an account, then SpringBoard entered safe mode.
- runtime.log: 15:05:23.989 request; 24.026 own chooser window shown; 24.044 another request; 24.145 native openApplication; 27.721 prepareWindow; 29.870 cancel -> forward.
- These are two calls, not proven to be the same request object. Old logs did not print object addresses.
- Crash: EXC_BAD_ACCESS/SIGBUS, possible PAC failure, PC 0x21721fa56; x0 points to stack 0x16d901ea0. LR is ParallelX+0x9fe8 (block invoke continuation). CloneX UUID BE275414-7C10-33E4-B678-5D1639B38E3C matches the delivered 1.10 arm64e slice.
- CloneX+0xd6d0 is the return site after forwarding the system request, not the crashing instruction. CloneX+0x55f8 is the chooser cancellation callback path. The completion lifetime issue is strongly supported, not experimentally reproduced here.

## Changes
- Keep the iOS 15 completion type `void (^)(NSError *)` and copy before async escape.
- Queue complete request objects per bundle while choice/switch is pending; no chooser-visible passthrough. Preserve each call's payload/completion; do not deduplicate by URL.
- One chooser globally; different bundles wait. Handoff each original request once, waiting for its result before the next. Do not URL-replay this full-request path.
- Cancel/presentation failure/switch failure return an NSError and never launch the current account as fallback.
- Copy chooser callbacks before detaching its root controller; release controller callbacks/owner on close.
- For account switches, observe the previous SBApplicationProcessState.pid and wait for ESRCH (up to 5 seconds). Unknown PID or timeout fails closed. Same-account cold launch does not wait for a scene that needs the original request to create it.
- Copy other async window completion objects; remove late chooser presentation in an already-started prepareWindow continuation.
- Bound selection/switch and downstream-result waiting. A timeout is failure, not a retry or a successful payment.

## ABI references
- https://github.com/lechium/iPhone_OS_15.5/blob/master/System/Library/PrivateFrameworks/SpringBoard/FBSystemServiceDelegate-Protocol.h
- https://github.com/lechium/iPhone_OS_15.5/blob/master/System/Library/PrivateFrameworks/SpringBoard/SBApplicationProcessState.h
- https://clang.llvm.org/docs/AutomaticReferenceCounting.html#blocks
- Example system-hook source: https://github.com/lindo-zy/PixPin/blob/main/Sources/SpringBoard/PXSpringBoardEntry.xm

## Acceptance (not run on device)
1. From payment source app: chooser stays visible; no WeChat split opens before a choice.
2. Cancel: no window launch, no payment replay, no safe mode.
3. Same-account cold/running: one selected account, original request payload delivered.
4. A -> B -> A: wait for old PID exit before delivering; abort safely on failure.
5. Two calls before selection: one chooser, each original callback finishes at most once.

Host Python checks are source/model regression guards only. CI compilation and static DEB verification do not prove on-device behavior. No remote install, touch, relaunch, or respring was performed for this fix.

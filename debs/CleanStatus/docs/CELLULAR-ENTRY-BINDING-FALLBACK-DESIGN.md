# CleanStatus 0.3.15 — first binding and fallback call-chain repair

## Authorization and baseline

Local correction only, separately approved after the pan hypothesis was withdrawn.
Base is published 0.3.14 commit `19d2a73f2da19181cc2c2eefe650938c0e76aaf5`, exact 160-file source ZIP SHA256 `ee1f88002a80274f8e8701817a1de466b9899ec0948dc53a83621e10ca8c921e`.
The rejected pan draft remains separate and on HOLD. No device access, push, CI,
iOS code generation, signing, packaging, install, respring or restart is allowed.

## Confirmed evidence and limits

The previously collected .14 cycle begins at SpringBoard 12:53:50. After the child
controller loads at 12:53:59.984, binding refuses at 12:54:00.208 because the
button is not visible. First bound occurs at 12:54:04.732, after the native
expanded callback at 04.720. After collapse at 06.592, two later presses present.
The 16.981 window touch is after those successes and does not identify a pan
winner. It is not used as a reason to change system gesture precedence.

The .14 helper takes directTouch and negates it internally. Both real receive
and begin callers negate it again, while action refuses fallback for a
currently direct-touchable button. The stable fallback pipeline is contradictory.
The actual cause of initial invisibility (specific ancestor/proxy/transition)
remains unknown. Correcting these source defects is not a device fix claim.

## Reused mechanism, not a new broad expander hook

The existing Wi-Fi/BT implementation prepares its recognizer on the native round
button during view loading, maintains a window fallback, and calls original
`didMoveToWindow` before rebinding its own marked button. This implementation is
left byte-identical; only its passive registration/window synchronization shape
is adapted to the cellular standard recognizer and existing independent target.

Apple UIView `addGestureRecognizer(_:)` attaches a recognizer and retains it; the
view and descendants define its hit-test scope. `didMoveToWindow()` is sent when
window changes and may observe a nil window. The fixed 15.5 UIView.h declares
this as an instance void/no-argument method. Source/official evidence supports
the hook signature and preparation shape, not the real .15 touch outcome.

## Production changes (only Cellular/LCSCellularHooks.m)

1. Prepare on a unique native cellular-owned button even while temporarily hidden
   or windowless. Preserve controller/class/ancestry/ownership/tap-contract gates;
   reject a button in a different live window. Registration itself performs no
   control action and accepts no hidden/windowless touch.
2. Load binding runs immediately after the original lifecycle method, as in the
   existing Wi-Fi entry. A checked, scoped round-button `didMoveToWindow` callback
   always forwards original once and only reconciles an already marked cellular
   button; it neither searches the whole window nor creates foreign states.
3. Idempotent synchronization maintains one passive fallback per current window,
   detaches it from an old window, and keeps the direct recognizer if unchanged.
   Keep it prepared through direct-touch capability changes; actual receive,
   begin and action are what decide which route may respond.
4. Both helper calls now pass the raw direct-touch value. `entryReady` is shared
   by receive/begin and rechecked before presentation: visible/attached, same
   owner/controller/window, native class and subtree, tap contract, feature,
   foreground, unlock and no duplicate/transitional presenter. Direct route
   requires direct touch; window route requires its absence and an initial point
   inside the existing bounds inset (-8,-10). No artificial click is generated.
5. Layout events are coalesced with a 0.25s trailing callback instead of discarded
   inside the throttle interval. The callback reads current state; lock/OFF/
   foreground loss cannot cause a late rebind.
6. Existing 0.45s/10pt thresholds, direct cancellation YES, fallback cancellation
   NO and delays NO remain. One late-state outcome uses a separate diagnostic
   row, still weak/generation guarded, so inventory budget cannot hide it.
   Presentation logs distinguish direct versus window route.

## Frozen adjacent behavior

Cellular policy header and all Wi-Fi/BT files, backends, SIM service/helper/
permissions/card, DataSwitch business, preferences resolver/store/notifications,
icons and animations are exact .14 bytes. The existing failure-relation,
expanded transition, disappearance retention and optional preview methods are
hash-pinned to .14. No pan/edge/dismissal precedence change is included.

## Validation layers

- Host C executes actual receive/begin/action qualification expressions, with
  independent modeled UIKit inputs. Positive/negative matrices include route,
  visibility, ownership, lock/OFF, window changes between phases, foreign/nil
  recognition and non-Began cancellation states. Bad real call-site mutations
  must compile then fail assertions.
- A Foundation-only fake-UIKit fixture extracts actual methods, not a rewritten
  binding algorithm. Nine groups cover hidden preparation, no-expanded-callback
  first start, same-window capability flips, window moves/idempotence, ownership
  and TouchDown guards, late revocation, cancellation, expanded lifetime and
  original callbacks. On Alpine this is syntax-only; macOS runtime is a later
  CI gate. The fake clock and gesture states are explicit boundaries, not UIKit.
- Whole existing core/policy/paths/UI/verifier regression and arm64e 15.5 parsing.

## Unverified / risks

Actual compact hit target, UIKit recognition/arbitration and visual overlap are
not run. If the compact view uses a different hidden proxy, passive binding alone
may still miss; do not weaken the live-visible gate or search arbitrary parents
without new evidence. No guarantee of zero six-control frames is made. Native
short-tap delivery, actual movement/OS cancellation, injection and AMFI acceptance
require separate build, package and user-device acceptance. Beginning a long
press then canceling it never implies a failed native pan is revived.

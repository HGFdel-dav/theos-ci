"""Source wiring checks complement the portable geometry policy and native adapter.
They check the *two writes* seen in the QX trace, not remote touch or rendering.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SRC = (ROOT/'Common/PXWindowMemory.m').read_text()

def body(begin, end):
    return SRC.split(begin, 1)[1].split(end, 1)[0]

class DockWakeHandoff(unittest.TestCase):
    def test_scaled_binding_defers_instead_of_applying_or_arming(self):
        bind = body('BOOL bindRecord =', 'PXWMLog(ticket, @"native_window_bound"')
        self.assertLess(bind.index('!PXWMCardInNormalSpace(ticket.card)'), bind.index('PXWMDeferDockFrame(ticket,1)'))
        self.assertLess(bind.index('PXWMDeferDockFrame(ticket,1)'), bind.index('else if (bindRecord && ticket.card)'))
        normal = bind.split('else if (bindRecord && ticket.card)', 1)[1]
        self.assertIn('card.frame = PXWMToRect(bindTarget);', normal)
        self.assertIn('PXWMScheduleInitialSettle(ticket)', normal)
        self.assertNotIn('card.frame =', bind[:bind.index('else if (bindRecord && ticket.card)')])
        defer = body('static void PXWMDeferDockFrame(PXWMContext *context, unsigned stage) {', '\n}')
        for flag in ('initialTargetActive', 'initialTargetAppliedAtBind', 'continuityActive'):
            self.assertIn('context.' + flag + ' = NO;', defer)
        for word in ('setFrame:', '.frame =', 'dispatch_after', 'setHostedInteractionEnabled:', 'saveGeometry:'):
            self.assertNotIn(word, defer)

    def test_settle_rechecks_current_window_and_never_retries_on_dock(self):
        settle = body('static void PXWMScheduleInitialSettle(PXWMContext *context) {', '/* Native layoutHost')
        guards = ('current.generation!=generation', 'PXWMBindingIsActive(current)', 'card!=scheduledCard',
                  'card.window!=scheduledWindow', 'PXWMFindCard(current.canvas)!=card', 'live[@"enabled"]',
                  'PXWMDeferDockFrame(current,2); return;')
        for guard in guards:
            self.assertLess(settle.index(guard), settle.index('card.frame = target;'))
        self.assertLess(settle.index('!PXWMCardInNormalSpace(card)'), settle.index('PXWMOriginalLayout(current.bridge'))
        self.assertEqual(settle.count('dispatch_after('), 1)

    def test_only_current_ticket_prepares_before_forwarding(self):
        block = body('forwardCompletion = ^(BOOL ok) {', 'BOOL returnedNormally')
        self.assertIn('ticket.generation==openingGeneration', block)
        self.assertIn('!ticket->native.cancelled', block)
        self.assertIn('PXWMBindingIsActive(ticket)', block)
        self.assertIn('PXWMPrepareInitialLayout(ticket)', block)
        self.assertNotIn('?: ticket', block)
        self.assertEqual(block.count('nativeCompletion(ok);'), 1)
        self.assertNotIn('return;', block.split('nativeCompletion(ok);', 1)[0])

    def test_expansion_stays_vendor_owned_and_input_passive(self):
        expand = body('static BOOL PXWMExpansionTarget(', 'static void PXWMRestoreDockTapped(')
        for g in ('PXWMMayApplyExpansion(', 'PXWMReadGeometry(context, YES', 'context.deferredDockFrame = NO;'):
            self.assertIn(g, expand)
        for forbidden in ('setHostedInteractionEnabled:', 'sceneActivated:', 'foregroundScene:', 'layer.cornerRadius =', 'removeAllAnimations'):
            self.assertNotIn(forbidden, SRC)
        inp = (ROOT/'Common/PXWindowInputDiagnostics.m').read_text()
        self.assertIn('[bundle isEqual:@"com.crossutility.quantumult-x"]',inp)
        self.assertEqual(inp.count('PXInputOriginalSendEvent(self,command,event)'),1)

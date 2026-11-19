/* Compatibility callbacks after removal of background name wake.
   Never read request mailboxes, schedule a pulse, present UI, or claim audio. */
static void MiniSightNameWakeUpdate(void) {
    gMiniSightNameWakeToken = nil;
    gMiniSightNameWakePresentationHeld = NO;
    gMiniSightNameWakeCancelling = NO;
    static BOOL logged = NO;
    if (!logged && gMiniSightContainer.length) {
        logged = YES;
        MSDiagEvent(@"name_wake", @"stop", @"ok", @{@"source": @"plugin", @"reason": @"feature_removed", @"active": @NO});
    }
}
static void MiniSightNameWakeCancel(NSString *reason, BOOL cancelPanel) {
    (void)reason; (void)cancelPanel;
    // A removed name owner must never close/cancel a manual ChatPanel session.
    MiniSightNameWakeUpdate();
}
static void MiniSightNameWakeReadRequest(void) { MiniSightNameWakeUpdate(); }

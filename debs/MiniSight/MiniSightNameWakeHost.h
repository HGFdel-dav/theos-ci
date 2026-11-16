/* Included only by Tweak.xm after existing host/UI implementations.
   SpringBoard paints and transports requests only; it never samples audio/TTS. */
static NSDictionary *gMSNWRequest;
static NSString *gMSNWRequestContainer;
static NSUInteger gMSNWResponseGeneration, gMSNWVoiceGeneration;
static BOOL gMSNWReadyConsumed;
static NSTimer *gMSNWPulse;
static NSTimeInterval gMSNWLastPublish;
static NSDictionary *gMSNWLastState;
static NSMutableArray<NSString *> *gMSNWSeenTokens;

static NSString *MiniSightNameWakeRevision(void) {
    id value = MiniSightPref(@"minisight.settings.revision");
    return [value isKindOfClass:NSString.class] && [value length] <= 128 ? value : @"";
}
static BOOL MiniSightNameWakeEnabled(void) {
    id value = MiniSightPref(@"minisight.wake.enabled");
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}
static BOOL MiniSightNameWakeSafe(BOOL *unlockedOut) {
    MiniSightReadScreenState();
    BOOL unlocked = gMiniSightScreenKnown && !gMiniSightScreenBlanked && [MiniSightMusicMonitor deviceIsUnlocked];
    if (unlockedOut) *unlockedOut = unlocked;
    id shownPref = MiniSightPref(@"minisight.shown");
    BOOL shown = MiniSightShown() && (!shownPref || ([shownPref isKindOfClass:NSNumber.class] && [shownPref boolValue]));
    return MSNWAllowed(MiniSightNameWakeEnabled(), shown, MiniSightStyle() == 1,
        gMiniSightResourcesReady && !gMiniSightResourceLoading, gMiniSightContainer.length > 0,
        MiniSightNameWakeRevision().length > 0, gMiniSightScreenKnown, gMiniSightScreenBlanked,
        unlocked, MiniSightRenderer() == 1, MiniSightMinisIsFrontmost());
}
static BOOL MiniSightNameWakeBusy(BOOL permitOwnedPanel) {
    MiniSightChatPanel *panel = MiniSightChatPanel.existingPanel;
    BOOL ownPanel = permitOwnedPanel && gMiniSightNameWakeToken.length &&
        [panel.nameWakeRequestToken isEqualToString:gMiniSightNameWakeToken] && !panel.isSending;
    MiniSightRecorder *rec = MiniSightRecorder.sharedRecorder;
    BOOL recording = rec.isQuarantined || (rec.state != MiniSightRecorderIdle && rec.state != MiniSightRecorderError);
    return MSNWBusy(gMiniSightConfirming, gMiniSightDragging, gMiniSightBurst, gMiniSightActivityExecuting,
        UIScreen.mainScreen.isCaptured, recording, gMiniSightRegionPicker && !gMiniSightRegionPicker.hidden,
        gMiniSightWindow.rootViewController.presentedViewController != nil, panel.isSending,
        (panel.isVisible || panel.currentVoiceGeneration != 0) && !ownPanel);
}
static void MiniSightNameWakeCancel(NSString *reason, BOOL cancelPanel) {
    if (!gMSNWRequest || gMiniSightNameWakeCancelling) return;
    gMiniSightNameWakeCancelling = YES;
    NSDictionary *request = gMSNWRequest;
    NSString *container = gMSNWRequestContainer, *token = gMiniSightNameWakeToken;
    NSUInteger response = gMSNWResponseGeneration, voice = gMSNWVoiceGeneration;
    // Clear host ownership BEFORE the callback; it cannot cancel a manual takeover.
    gMSNWRequest = nil; gMSNWRequestContainer = nil; gMiniSightNameWakeToken = nil;
    gMSNWResponseGeneration = 0; gMSNWVoiceGeneration = 0; gMSNWReadyConsumed = NO;
    MiniSightChatPanel *panel = MiniSightChatPanel.existingPanel;
    panel.nameWakeCancellationHandler = nil;
    panel.nameWakeVoiceFinishedHandler = nil;
    if (cancelPanel && token.length) [panel cancelNameWakeRequestForToken:token];
    // Cancelling a voice lease is not permission to erase a user-owned draft.
    gMiniSightNameWakePresentationHeld = panel.isVisible;
    [MiniSightNameWakeBridge.sharedBridge replyToRequest:request container:container state:@"cancelled"
        responseGeneration:response voiceGeneration:voice reason:reason ?: @"cancelled"];
    gMiniSightNameWakeCancelling = NO;
}
static void MiniSightNameWakeUpdate(void) {
    NSCAssert(NSThread.isMainThread, @"Name wake host is main-thread owned");
    BOOL unlocked = NO, allowed = MiniSightNameWakeSafe(&unlocked);
    if (gMSNWRequest) {
        BOOL context = [gMSNWRequestContainer isEqualToString:gMiniSightContainer] &&
            [gMSNWRequest[@"revision"] isEqualToString:MiniSightNameWakeRevision()];
        MiniSightChatPanel *panel = MiniSightChatPanel.existingPanel;
        BOOL current = gMSNWReadyConsumed ? (gMSNWVoiceGeneration != 0 && panel.currentVoiceGeneration == gMSNWVoiceGeneration) :
            (gMSNWResponseGeneration == 0 || [panel isNameWakeResponseCurrent:gMSNWResponseGeneration]);
        BOOL anchor = !gMSNWResponseGeneration || (gMiniSightPet.window == gMiniSightWindow &&
            gMiniSightWindow && !gMiniSightWindow.hidden && panel.anchorView == gMiniSightPet);
        if (!allowed || !context || !current || !anchor || MiniSightNameWakeBusy(YES))
            MiniSightNameWakeCancel(!context ? @"context_changed" : (!allowed ? @"unsafe_state" : @"panel_changed"), YES);
    }
    BOOL enabled = MiniSightNameWakeEnabled();
    if (enabled && !gMSNWPulse) {
        gMSNWPulse = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
            (void)timer; MiniSightNameWakeUpdate();
        }];
        [NSRunLoop.mainRunLoop addTimer:gMSNWPulse forMode:NSRunLoopCommonModes];
    } else if (!enabled && gMSNWPulse) { [gMSNWPulse invalidate]; gMSNWPulse = nil; }
    NSDictionary *state = @{@"container": gMiniSightContainer ?: @"", @"revision": MiniSightNameWakeRevision(),
        @"unlocked": @(unlocked), @"allowed": @(allowed), @"busy": @(MiniSightNameWakeBusy(NO))};
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if ([state isEqualToDictionary:gMSNWLastState] && (!enabled || now - gMSNWLastPublish < 1.0)) return;
    gMSNWLastState = state; gMSNWLastPublish = now;
    [MiniSightNameWakeBridge.sharedBridge publishContainer:gMiniSightContainer revision:MiniSightNameWakeRevision()
        unlocked:unlocked allowed:allowed busy:[state[@"busy"] boolValue]];
}
static void MiniSightNameWakeDecline(NSDictionary *request, NSString *reason) {
    [MiniSightNameWakeBridge.sharedBridge replyToRequest:request container:gMiniSightContainer state:@"declined"
        responseGeneration:0 voiceGeneration:0 reason:reason];
}
static void MiniSightNameWakeHandle(NSDictionary *request) {
    if (![MiniSightNameWakeBridge.sharedBridge request:request matchesRevision:MiniSightNameWakeRevision()]) return;
    NSString *token = request[@"token"], *action = request[@"action"];
    BOOL same = gMSNWRequest && [token isEqualToString:gMiniSightNameWakeToken];
    if ([action isEqualToString:@"cancel"]) {
        if (same) MiniSightNameWakeCancel(@"app_cancel", YES);
        return;
    }
    if ([action isEqualToString:@"ready"]) {
        if (!same || gMSNWReadyConsumed) return; // Cannot resurrect another lifecycle or replay input.
        MiniSightChatPanel *panel = MiniSightChatPanel.existingPanel;
        if (!MSNWReadyMayConsume(same, gMSNWReadyConsumed, gMSNWResponseGeneration,
            [panel isNameWakeResponseCurrent:gMSNWResponseGeneration], MiniSightNameWakeSafe(NULL), MiniSightNameWakeBusy(YES))) {
            MiniSightNameWakeCancel(@"ready_not_current", YES); return;
        }
        gMSNWReadyConsumed = YES; // Consume BEFORE calling UI/transport callbacks.
        panel.nameWakeVoiceRequestDeferred = YES;
        BOOL started = [panel beginNameWakeVoiceInputForGeneration:gMSNWResponseGeneration];
        panel.nameWakeVoiceRequestDeferred = NO;
        if (!started || !gMSNWRequest || ![token isEqualToString:gMiniSightNameWakeToken]) {
            MiniSightNameWakeCancel(@"voice_unavailable", YES); return;
        }
        gMSNWVoiceGeneration = panel.currentVoiceGeneration;
        [MiniSightNameWakeBridge.sharedBridge replyToRequest:request container:gMSNWRequestContainer state:@"voice_requested"
            responseGeneration:gMSNWResponseGeneration voiceGeneration:gMSNWVoiceGeneration reason:@"host_confirmed"];
        MiniSightNameWakeUpdate();
        return;
    }
    if (!gMSNWSeenTokens) gMSNWSeenTokens = [NSMutableArray array];
    if ([gMSNWSeenTokens containsObject:token]) return; // Duplicate hit never replays text.
    [gMSNWSeenTokens addObject:token];
    if (gMSNWSeenTokens.count > 64) [gMSNWSeenTokens removeObjectAtIndex:0];
    if (gMSNWRequest || !MiniSightNameWakeSafe(NULL) || MiniSightNameWakeBusy(NO)) {
        MiniSightNameWakeDecline(request, @"unsafe_or_busy"); return;
    }
    gMSNWRequest = [request copy]; gMSNWRequestContainer = [gMiniSightContainer copy];
    gMiniSightNameWakeToken = token; gMSNWReadyConsumed = NO;
    MiniSightShow(); // Normal completed resource/build path; no App foreground URL.
    if (!gMiniSightPet || gMiniSightPet.window != gMiniSightWindow || !gMiniSightWindow.windowScene || gMiniSightWindow.hidden) {
        MiniSightNameWakeCancel(@"missing_pet_anchor", YES); return;
    }
    MiniSightChatPanel *panel = MiniSightChatPanel.sharedPanel;
    panel.containerPath = gMiniSightContainer; panel.appearancePreferences = gMiniSightPreferences ?: @{};
    panel.anchorView = gMiniSightPet; panel.hidePetHandler = ^{ MiniSightUserHide(); };
    panel.nameWakeCancellationHandler = ^{ MiniSightNameWakeCancel(@"panel_control", NO); MiniSightNameWakeUpdate(); };
    MiniSightHideBubble();
    if (![panel showNameWakeResponseInWindowScene:gMiniSightWindow.windowScene]) {
        MiniSightNameWakeCancel(@"response_unavailable", YES); return;
    }
    panel.nameWakeRequestToken = token;
    gMiniSightNameWakePresentationHeld = YES;
    __weak MiniSightChatPanel *weakPanel = panel;
    panel.nameWakeVoiceFinishedHandler = ^{
        MiniSightChatPanel *panel = weakPanel;
        if (!gMSNWRequest || ![gMiniSightNameWakeToken isEqualToString:token]) return;
        // Final text already belongs to the panel. End only the audio request,
        // without posting cancelled (which could race the captured transcript).
        gMSNWRequest = nil; gMSNWRequestContainer = nil; gMiniSightNameWakeToken = nil;
        gMSNWResponseGeneration = 0; gMSNWVoiceGeneration = 0; gMSNWReadyConsumed = NO;
        panel.nameWakeCancellationHandler = nil;
        panel.nameWakeVoiceFinishedHandler = nil;
        gMiniSightNameWakePresentationHeld = panel.isVisible;
        MiniSightNameWakeUpdate();
    };
    gMSNWResponseGeneration = panel.nameWakeResponseGeneration;
    if (!gMSNWResponseGeneration || ![panel isNameWakeResponseCurrent:gMSNWResponseGeneration]) {
        MiniSightNameWakeCancel(@"response_not_current", YES); return;
    }
    [MiniSightNameWakeBridge.sharedBridge replyToRequest:request container:gMSNWRequestContainer state:@"accepted"
        responseGeneration:gMSNWResponseGeneration voiceGeneration:0 reason:@"host_confirmed"];
    MiniSightNameWakeUpdate();
    NSString *held = [token copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([held isEqualToString:gMiniSightNameWakeToken] && !gMSNWReadyConsumed) {
            MiniSightNameWakeCancel(@"ready_timeout", YES); MiniSightNameWakeUpdate();
        }
    });
}
static void MiniSightNameWakeReadRequest(void) {
    if (!gMiniSightResourcesReady) {
        MiniSightRequestResources(NO, ^{ MiniSightNameWakeUpdate(); MiniSightNameWakeReadRequest(); });
        return; // One coalesced lazy resource load, never a per-pulse directory scan.
    }
    NSString *container = [gMiniSightContainer copy], *revision = [MiniSightNameWakeRevision() copy];
    [MiniSightNameWakeBridge.sharedBridge readRequestInContainer:container revision:revision completion:^(NSDictionary *request) {
        if (request && [container isEqualToString:gMiniSightContainer] && [revision isEqualToString:MiniSightNameWakeRevision()])
            MiniSightNameWakeHandle(request);
    }];
}

// SpringBoard: one physical panel for two displays. The cover and the inner
// display share this guest's only scanout, the primary; open, SpringBoard
// composites the inner display onto it.

#import "FoldDisplayPrivate.h"
#include <notify.h>
#include <math.h>
#include <os/lock.h>

static void vpShowInnerDisplay(BOOL shown);
static void vpFollowInnerPages(void);
static void vpHoldPanel(void);
static void vpPrewarmPanelHoldContext(unsigned attempt);
static void vpWatchNativePanelContent(void);
static void vpNativeContentModeDidChange(unsigned long generation, BOOL finished);
static unsigned long vpPanelHoldGeneration;
static BOOL vpPanelHoldUsesNativeLifecycle;
static void vpReleasePanelHold(NSString *reason);
static void vpPanelHoldFollowOwner(BOOL innerOwns);

// MARK: - power

// SpringBoard powers each panel through its CADisplayStateControl (state 1
// on, 0 off): open, the cover (primary, display 1) goes off and the inner
// display on; closed, the reverse. On this guest the primary is the only
// scanout, and open it has to show the inner display, which SpringBoard
// composites onto it (vpShowInnerDisplay). Which panel the scanout shows
// follows the fold, not the power requests: the panel holding the primary
// content (SBDisplayContentModeCoordinator's primaryWindowScene) owns it, and
// the scanout is on while that panel wants to be. SpringBoard powers the
// panel facing away as it likes (closing does not turn the inner display off,
// and closing a sleeping device lights the inner display for a moment); on a
// real Duo that panel is folded away, so here it is not shown. The compositor
// and backboardd's touch routing follow the inner display's applied state.
static IMP vpOriginalTransitionDisplayState;
static id vpPrimaryStateControl, vpInnerStateControl;
static long long vpPrimaryWantedState = 1, vpPrimaryAppliedState = 1, vpInnerWantedState, vpInnerAppliedState = -1;
// Who owns the panel: 1 the inner display, 0 the cover, -1 not yet resolved.
static int vpInnerOwnedPanel = -1;
// The fold handoff (vpHoldHandoff).
static BOOL vpHandoffHeld;
static unsigned long vpHandoffGeneration;
static void vpReleaseHandoff(NSString *reason);
static void vpApplyPanelStates(id primaryCompletion, id innerCompletion);

// The cover until the inner display is resolved and holds the primary content.
static BOOL vpInnerOwnsPanel(void) {
    id innerScene = vpSpringBoardWindowScene(YES);
    id coordinator = vpReadObject(vpReadObject(objc_getClass("UIApplication"), "sharedApplication"), "displayContentModeCoordinator");
    return innerScene && vpReadObject(coordinator, "primaryWindowScene") == innerScene;
}

static unsigned int vpStateControlDisplayId(id control) {
    Ivar ivar = class_getInstanceVariable(object_getClass(control), "_display_id");
    if (!ivar || strcmp(ivar_getTypeEncoding(ivar), "I") != 0) return 0;
    return *(unsigned int *)((uint8_t *)(__bridge void *)control + ivar_getOffset(ivar));
}

// When the panel last came on (system uptime), for vpFollowContentModeTransition.
static NSTimeInterval vpPanelOnAt;

// SpringBoard reports the screen blanked (hasBlankedScreen) both when it turns
// the panel off and when it dims it to the always-on Lock Screen, which keeps
// the panel on and drawing. The VM window covers the panel while the screen
// is off (display.orientation's screen_off) so that, coming on, it does not
// show the frame from before it went off. vphoned reports this state instead,
// so the window leaves the always-on Lock Screen uncovered. The panel counts
// as dark from going off until SpringBoard lights the screen again, so a wake
// from off is covered as before.
static int vpBlankedToken = -1, vpPanelDarkToken = -1;
static BOOL vpPanelWentDark;
// When SpringBoard last blanked or unblanked the screen (system uptime). The
// power button blanks it without turning the panel off, and a fold made then
// wakes it as the fold runs: the hand-over hold stays out of that.
static NSTimeInterval vpScreenBlankChangedAt;

static void vpPublishPanelDark(void) {
    if (vpPanelDarkToken >= 0) notify_set_state(vpPanelDarkToken, vpPanelWentDark ? 2 : 1);
}

static BOOL vpScreenBlanked(void) {
    uint64_t blanked = 0;
    if (vpBlankedToken >= 0) notify_get_state(vpBlankedToken, &blanked);
    return blanked != 0;
}

BOOL vpPanelIsAlwaysOn(void) { return vpScreenBlanked() && !vpPanelWentDark; }

static void vpFollowPanelPower(long long state) {
    if (!state) vpPanelWentDark = YES;
    else if (!vpScreenBlanked()) vpPanelWentDark = NO;
    vpPublishPanelDark();
}

static void vpInstallPanelDark(void) {
    if (notify_register_check(vpPanelDarkNotification, &vpPanelDarkToken) != NOTIFY_STATUS_OK) {
        vpPanelDarkToken = -1;
        return;
    }
    notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &vpBlankedToken, dispatch_get_main_queue(), ^(int token) {
        (void)token;
        vpScreenBlankChangedAt = NSProcessInfo.processInfo.systemUptime;
        if (vpScreenBlanked()) vpReleasePanelHold(@"screen blanked");
        if (vpScreenBlanked() && vpHandoffHeld) {
            vpReleaseHandoff(@"screen blanked");
            vpApplyPanelStates(nil, nil);
        }
        if (vpScreenBlanked() || !vpPrimaryAppliedState) return;
        vpPanelWentDark = NO;
        vpPublishPanelDark();
    });
    vpPanelWentDark = !vpPrimaryAppliedState;
    vpPublishPanelDark();
    vpInstallAlwaysOnWakePolicy();
}

static void vpApplyPanelState(id control, long long state, long long *applied, id completion) {
    if (!control || (state == *applied && !completion)) return;
    if (vpFoldTraceEnabled()) vpFoldTrace(@"panel_power", NULL, nil, @{@"display": @(vpStateControlDisplayId(control)), @"from": @(*applied), @"to": @(state), @"owner": @(vpInnerOwnedPanel)});
    if (control == vpPrimaryStateControl && state && !*applied) vpPanelOnAt = NSProcessInfo.processInfo.systemUptime;
    *applied = state;
    if (control == vpPrimaryStateControl) vpFollowPanelPower(state);
    if (control == vpPrimaryStateControl && !state) {
        if (NSThread.isMainThread) vpReleasePanelHold(@"panel off");
        else dispatch_async(dispatch_get_main_queue(), ^{ vpReleasePanelHold(@"panel off"); });
    }
    ((void (*)(id, SEL, long long, id))vpOriginalTransitionDisplayState)(control,
        sel_registerName("transitionToDisplayState:withCompletion:"), state, completion);
}

// A fold hands the panel to the arriving display before SpringBoard asks that
// display to come on. Closing, the cover still wants the state it was left in
// when the device opened (off) until SpringBoard lights it after the swap, up
// to a second later; opening after SpringBoard turned the folded-away inner
// display off (3 s after a close) is the same. Following the owner's wanted
// state at the swap turned the one scanout off in between: opaque black in the
// guest's own capture and on the host. A swap made while the panel is lit
// keeps it lit until the arriving display is asked about, the screen blanks,
// or 2 s pass. It never holds the panel off.
static void vpReleaseHandoff(NSString *reason) {
    if (!vpHandoffHeld) return;
    vpHandoffHeld = NO;
    vpHandoffGeneration++;
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: handoff released (%@)", reason]);
}

static void vpHoldHandoff(BOOL innerOwns) {
    if (!vpPrimaryAppliedState || (innerOwns ? vpInnerWantedState : vpPrimaryWantedState)) return;
    vpHandoffHeld = YES;
    unsigned long generation = ++vpHandoffGeneration;
    vpFoldDisplayLog(@"inner display: handoff held");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (generation != vpHandoffGeneration) return;
        vpReleaseHandoff(@"timeout");
        vpApplyPanelStates(nil, nil);
    });
}

static void vpUpdatePanelOwner(void) {
    BOOL innerOwns = vpInnerOwnsPanel();
    if (innerOwns == vpInnerOwnedPanel) return;
    vpInnerOwnedPanel = innerOwns;
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: panel owned by the %@", innerOwns ? @"inner display" : @"cover"]);
    vpHoldHandoff(innerOwns);
    vpPanelHoldFollowOwner(innerOwns);
}

static void vpApplyPanelStates(id primaryCompletion, id innerCompletion) {
    vpUpdatePanelOwner();
    BOOL innerOwns = vpInnerOwnedPanel == 1;
    BOOL lit = (innerOwns ? vpInnerWantedState : vpPrimaryWantedState) || vpHandoffHeld;
    vpApplyPanelState(vpPrimaryStateControl, lit ? 1 : 0, &vpPrimaryAppliedState, primaryCompletion);
    long long inner = innerOwns && lit ? 1 : 0;
    BOOL changed = inner != vpInnerAppliedState;
    vpApplyPanelState(vpInnerStateControl, inner, &vpInnerAppliedState, innerCompletion);
    if (changed && vpInnerStateControl) {
        if (NSThread.isMainThread) vpShowInnerDisplay(inner != 0);
        else dispatch_async(dispatch_get_main_queue(), ^{ vpShowInnerDisplay(inner != 0); });
    }
}

// SpringBoard asks for a transition only when it wants a state the panel is
// not in; after a SpringBoard restart the inner display may already be lit and
// is never asked about. So until it is, its wanted state is the state it has.
static void vpAdoptInnerStateControl(void) {
    if (vpInnerStateControl) return;
    for (id display in vpReadObject(objc_getClass("CADisplay"), "displays") ?: @[]) {
        if (!vpIsInnerDisplay(display)) continue;
        id control = vpReadObject(display, "stateControl");
        Method current = class_getInstanceMethod(object_getClass(control), sel_registerName("displayState"));
        if (!current || strcmp(method_getTypeEncoding(current), "q16@0:8") != 0) return;
        vpInnerWantedState = vpInnerAppliedState =
            ((long long (*)(id, SEL))objc_msgSend)(control, sel_registerName("displayState")) != 0;
        vpInnerStateControl = control;
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: adopted state %lld", vpInnerWantedState]);
        if (vpInnerWantedState) dispatch_async(dispatch_get_main_queue(), ^{ vpShowInnerDisplay(YES); });
        return;
    }
}

static void vpSharedScanoutTransition(id self, SEL selector, long long state, id completion) {
    // Some native transition styles change ownership before requesting power,
    // without calling SpringBoard's primary-swap observer. Reconcile before
    // changing wanted state, so the arriving panel can hold the lit scanout.
    vpUpdatePanelOwner();
    unsigned int displayId = vpStateControlDisplayId(self);
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: display %u wants state %lld", displayId, state]);
    if (displayId == 1) {
        vpAdoptInnerStateControl();
        vpPrimaryStateControl = self;
        vpPrimaryWantedState = state;
        if (vpInnerOwnedPanel == 0) vpReleaseHandoff(@"cover asked");
        vpApplyPanelStates(completion, nil);
        return;
    }
    id innerDisplay = nil;
    for (id display in vpReadObject(objc_getClass("CADisplay"), "displays") ?: @[])
        if ([[display valueForKey:@"displayId"] unsignedIntValue] == displayId && vpIsInnerDisplay(display)) innerDisplay = display;
    if (!innerDisplay) {
        ((void (*)(id, SEL, long long, id))vpOriginalTransitionDisplayState)(self, selector, state, completion);
        return;
    }
    vpInnerStateControl = self;
    vpInnerWantedState = state;
    if (vpInnerOwnedPanel == 1) vpReleaseHandoff(@"inner display asked");
    vpApplyPanelStates(nil, completion);
}

// A fold moves the primary content to the other panel, which takes the
// scanout over even when no power request comes with it. An instant or fading
// transition has swapped the primary content by the time it is performed; an
// interactive one (the continuous fold of a hinge sweep) swaps it as it
// finishes, so the swap itself is followed too. SpringBoard keeps the panel it
// left lit for 3 s after a swap, and without this the scanout went on showing
// it (black) until then.
static IMP vpOriginalPerformContentModeTransition, vpOriginalHandlePrimarySwap;
static IMP vpOriginalSnapshotHandleTransition, vpOriginalShouldDeferEffectUntilReveal;

static BOOL vpPanelAwakeFoldEligible(void) {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    return vpPrimaryAppliedState && now - vpPanelOnAt >= 1 && !vpScreenBlanked() && now - vpScreenBlankChangedAt >= 1;
}

static void vpApplyPanelOwner(void) {
    vpApplyPanelStates(nil, nil);
}

static void vpFollowPanelOwner(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ vpApplyPanelOwner(); });
}

// SpringBoard's fold effect fades the panel being folded away to black and
// the arriving one in from black: two screens on hardware, about 0.12 s of
// black on this one panel each time it opens. Without the fade the cover dims
// and blurs and the inner display takes over at the swap. A fold made while
// the screen is dark runs only as it comes on (the pose provider commits on
// display frames), and there the fade hides what the effect carries over from
// the inner display (its Home Screen, sideways on the cover), so it stays for
// a fold that starts with the panel off or just lit.
static void vpSetFoldFadeToBlack(BOOL enabled) {
    id settings = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("SBDeviceContinuousFoldInteractionDomain"), sel_registerName("rootSettings"));
    SEL setFade = sel_registerName("setFadeToBlackEnabled:");
    if ([settings respondsToSelector:setFade]) ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, setFade, enabled);
}

static NSString *vpTransitionStyleName(id transitionCoordinator) {
    id context = vpReadObject(transitionCoordinator, "currentContext");
    Method style = class_getInstanceMethod(object_getClass(context), sel_registerName("transitionStyle"));
    NSString *(*describe)(NSInteger) = dlsym(RTLD_DEFAULT, "SBFStringForDisplayContentModeTransitionStyle");
    if (!style || strcmp(method_getTypeEncoding(style), "q16@0:8") || !describe) return nil;
    return describe(((NSInteger (*)(id, SEL))objc_msgSend)(context, sel_registerName("transitionStyle")));
}

static void vpFollowContentModeTransition(id self, SEL selector, id transitionCoordinator) {
    vpRefreshPanelOrientationLock();
    NSString *style = vpTransitionStyleName(transitionCoordinator);
    if (vpFoldTraceEnabled()) {
        vpFoldTrace(@"transition_perform", NULL, nil, @{@"owner": @(vpInnerOwnedPanel),
            @"coordinator": NSStringFromClass([transitionCoordinator class]), @"transition_style": style ?: @"unavailable"});
    }
    BOOL awake = vpPanelAwakeFoldEligible();
    vpSetFoldFadeToBlack(!awake);
    if (awake) {
        vpHoldPanel();
        vpWatchNativePanelContent();
    }
    SEL changed = sel_registerName("addDisplayContentModeDidChangeHandlerFromParticipant:handler:");
    Method didChange = class_getInstanceMethod(object_getClass(transitionCoordinator), changed);
    SEL postflight = sel_registerName("addPostflightActionsFromParticipant:actions:");
    Method didFinish = class_getInstanceMethod(object_getClass(transitionCoordinator), postflight);
    BOOL hasPostflight = didFinish && !strcmp(method_getTypeEncoding(didFinish), "v32@0:8@16@?24");
    unsigned long generation = vpPanelHoldGeneration;
    if (didChange && !strcmp(method_getTypeEncoding(didChange), "v32@0:8@16@?24")) {
        static id participant;
        if (!participant) participant = [NSObject new];
        ((void (*)(id, SEL, id, id))objc_msgSend)(transitionCoordinator, changed, participant, ^(id context, id lockProvider) {
            (void)context; (void)lockProvider;
            vpNativeContentModeDidChange(generation, !hasPostflight);
        });
        vpPanelHoldUsesNativeLifecycle = YES;
        if (hasPostflight) ((void (*)(id, SEL, id, id))objc_msgSend)(transitionCoordinator, postflight, participant, ^(id context, id lockProvider) {
            (void)context; (void)lockProvider;
            vpNativeContentModeDidChange(generation, YES);
        });
    } else vpFoldDisplayLog(@"inner display: content-mode completion ABI unavailable");
    ((void (*)(id, SEL, id))vpOriginalPerformContentModeTransition)(self, selector, transitionCoordinator);
    vpFollowPanelOwner();
}

// At once, in SpringBoard's own transaction: it hides the content leaving
// the panel here, and a later hop showed the panel empty in between.
static void vpFollowPrimarySwap(id self, SEL selector, id coordinator, id from, id to, id lockProvider) {
    // This also covers a swap not seen at the transition entry. A frame
    // rendered as the screen wakes may be the one
    // from before it blanked (bde6440c), so only a fold made awake is held.
    BOOL eligible = vpPanelAwakeFoldEligible();
    if (vpFoldTraceEnabled()) {
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        vpFoldTrace(@"swap", NULL, nil, @{@"eligible": @(eligible), @"owner": @(vpInnerOwnedPanel),
            @"panel_on_age": @(now - vpPanelOnAt), @"blank_changed_age": @(now - vpScreenBlankChangedAt)});
    }
    if (eligible)
        vpHoldPanel();
    ((void (*)(id, SEL, id, id, id, id))vpOriginalHandlePrimarySwap)(self, selector, coordinator, from, to, lockProvider);
    vpApplyPanelOwner();
}

// SBContinuousFoldSnapshotCoordinator._installCloakForConfiguration: is
// objc_direct and cannot be swizzled directly; it runs inside the coordinator's
// phase -1 preflight action. Registering a phase 0 preflight action right after
// handleDisplayContentModeTransition: neutralizes the opaque black cloak view
// before the first CoreAnimation commit while preserving overlay lifetime.
static void vpClearSnapshotCloak(id snapshotCoordinator) {
    if (!vpPanelAwakeFoldEligible()) return;
    id contentsView = vpReadObjectIvar(snapshotCoordinator, "_cloakContentsView");
    if (!contentsView) return;
    id clear = vpReadObject(objc_getClass("UIColor"), "clearColor");
    if (clear) ((void (*)(id, SEL, id))objc_msgSend)(contentsView, sel_registerName("setBackgroundColor:"), clear);
    ((void (*)(id, SEL, double))objc_msgSend)(contentsView, sel_registerName("setAlpha:"), 0.0);
    if (vpFoldTraceEnabled()) vpFoldTrace(@"cloak_cleared", NULL, nil, @{@"owner": @(vpInnerOwnedPanel)});
}

static void vpSnapshotHandleTransition(id self, SEL selector, id coordinator, id transitionCoordinator) {
    if (vpOriginalSnapshotHandleTransition)
        ((void (*)(id, SEL, id, id))vpOriginalSnapshotHandleTransition)(self, selector, coordinator, transitionCoordinator);
    SEL preflight = sel_registerName("addPreflightActionsFromParticipant:actions:");
    Method addPreflight = transitionCoordinator
        ? class_getInstanceMethod(object_getClass(transitionCoordinator), preflight) : NULL;
    if (!addPreflight || strcmp(method_getTypeEncoding(addPreflight), "v32@0:8@16@?24") != 0) return;
    static id cloakParticipant;
    if (!cloakParticipant) cloakParticipant = [NSObject new];
    __weak id weakSelf = self;
    ((void (*)(id, SEL, id, id))objc_msgSend)(transitionCoordinator, preflight, cloakParticipant, ^(id context) {
        (void)context;
        id strongSelf = weakSelf;
        if (strongSelf) vpClearSnapshotCloak(strongSelf);
    });
}

// Without an opaque cloak on the arriving panel, deferring the arriving
// fold effect until didChange leaves Main (close) or Inner (open) static
// across [swap .. didChange]. Run the native effect immediately when awake
// so blur and perspective track live instead of stalling between displays.
static BOOL vpShouldDeferEffectUntilReveal(id self, SEL selector, id context) {
    BOOL deferred = vpOriginalShouldDeferEffectUntilReveal
        ? ((BOOL (*)(id, SEL, id))vpOriginalShouldDeferEffectUntilReveal)(self, selector, context)
        : NO;
    if (!deferred) return NO;
    return !vpPanelAwakeFoldEligible();
}

static void vpInstallContentModeOwnership(void) {
    Method perform = class_getInstanceMethod(objc_getClass("SBDisplayContentModeCoordinator"),
        sel_registerName("performDisplayContentModeTransitionWithCoordinator:"));
    if (!perform || strcmp(method_getTypeEncoding(perform), "v24@0:8@16") != 0) {
        vpFoldDisplayLog(@"inner display: content mode transition ABI unavailable");
        return;
    }
    vpOriginalPerformContentModeTransition = method_setImplementation(perform, (IMP)vpFollowContentModeTransition);
    // SpringBoard (the application) observes every primary swap, once each.
    Method swap = class_getInstanceMethod(objc_getClass("SpringBoard"), sel_registerName(
        "displayContentModeCoordinator:handleSwapTransitionFromPrimaryWindowScene:toPrimaryWindowScene:withContinuationLockProvider:"));
    if (!swap || strcmp(method_getTypeEncoding(swap), "v48@0:8@16@24@32@40") != 0) {
        vpFoldDisplayLog(@"inner display: primary swap ABI unavailable");
        return;
    }
    vpOriginalHandlePrimarySwap = method_setImplementation(swap, (IMP)vpFollowPrimarySwap);
    Method snapshotTransition = class_getInstanceMethod(objc_getClass("SBContinuousFoldSnapshotCoordinator"),
        sel_registerName("displayContentModeCoordinator:handleDisplayContentModeTransition:"));
    const char *snapshotEncoding = snapshotTransition ? method_getTypeEncoding(snapshotTransition) : NULL;
    if (!snapshotEncoding || strcmp(snapshotEncoding, "v32@0:8@16@24") != 0) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: snapshot transition ABI unavailable (%s)", snapshotEncoding ?: "missing"]);
    } else {
        vpOriginalSnapshotHandleTransition = method_setImplementation(snapshotTransition, (IMP)vpSnapshotHandleTransition);
    }
    Method defer = class_getInstanceMethod(objc_getClass("SBContinuousFoldController"),
        sel_registerName("_shouldDeferEffectUntilRevealForContext:"));
    const char *deferEncoding = defer ? method_getTypeEncoding(defer) : NULL;
    if (!deferEncoding || (strcmp(deferEncoding, "B24@0:8@16") != 0 && strcmp(deferEncoding, "c24@0:8@16") != 0)) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: fold effect defer ABI unavailable (%s)", deferEncoding ?: "missing"]);
    } else {
        vpOriginalShouldDeferEffectUntilReveal = method_setImplementation(defer, (IMP)vpShouldDeferEffectUntilReveal);
    }
}

void vpInstallSharedPanel(void) {
    Method transition = class_getInstanceMethod(objc_getClass("CADisplayStateControl"),
        sel_registerName("transitionToDisplayState:withCompletion:"));
    const char *encoding = transition ? method_getTypeEncoding(transition) : "missing";
    Ivar displayId = class_getInstanceVariable(objc_getClass("CADisplayStateControl"), "_display_id");
    if (strcmp(encoding, "v32@0:8q16@?24") != 0 || !displayId || strcmp(ivar_getTypeEncoding(displayId), "I") != 0) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: shared scanout ABI unavailable (%s)", encoding]);
        return;
    }
    vpOriginalTransitionDisplayState = method_setImplementation(transition, (IMP)vpSharedScanoutTransition);
    vpInstallPanelDark();
    vpInstallContentModeOwnership();
    dispatch_async(dispatch_get_main_queue(), ^{ vpPrewarmPanelHoldContext(0); });
    vpFollowInnerPages();
    vpSetFoldFadeToBlack(NO);
    vpFoldDisplayLog(@"inner display: shared scanout installed");
}

// MARK: - compositing

// The render server's own clone of a display (addClone:options:) shows
// nothing on this guest's paravirtual panel (black with every option), so
// SpringBoard shows the inner display there itself, in a layer at the top of
// Main's root scene window (UIRootSceneWindow, the window Main's scenes
// are hosted in). It is not in a window of SB-main, because open,
// SpringBoard gives the cover (Main) auxiliary content and takes its scene's
// windows off screen. Like every window it works in points, so UIKit's
// screen capture sees it as it sees the rest of the screen. Touches never
// come here: the digitizer belongs to the inner display while it is lit
// (FoldDisplayBackboard.m).
//
// The render server draws the inner display as the inner display, so what
// the panel shows is that display's own frame: backdrops (Liquid Glass)
// sample the inner display, and SpringBoard's portals and scene hosts work
// as they do there. Drawing the inner display's layers on the primary
// display instead does not hold up. A CALayerHost of each inner window
// takes the window's context over (the render server keeps one host per
// context, and each window is already hosted in the inner display's root
// scene window), so the two hosts took the windows from each other on every
// commit and the panel lost windows for a frame or two at app launches and
// going home; a cross-display portal of the root scene window keeps the
// windows where they are, but SpringBoard's own portals inside it and every
// backdrop are drawn against the primary display: holes beside a launching
// app's icon, a black frame going home, and ghosting glass.
//
// The layer hosts backboardd's context that shows the page the inner display
// last finished (FoldDisplayInnerPages.m), so the panel shows each frame the
// inner display draws, and only those. Where backboardd publishes no context,
// SpringBoard has the render server draw the inner display into a surface of
// its own on every primary frame (CARenderServerRenderDisplay), a second full
// render each frame. Three surfaces take turns then, so the render server
// never draws into the one the panel shows or the one it showed last.
static id vpInnerPanelRoot, vpInnerPanelImage, vpInnerPanelRefresh;
static void *vpInnerPanelSurfaces[3];
static int vpInnerPanelShown;
// The hosted context, 0 while SpringBoard draws the inner display itself.
static uint32_t vpInnerPanelContextId;
static BOOL vpInnerPanelRendering; // main thread only
static dispatch_queue_t vpInnerPanelQueue;
static void (*vpRenderDisplay)(mach_port_t, CFStringRef, void *, int32_t, int32_t);
// CAFrameRateRange: minimum, maximum, preferred.
typedef struct { float minimum, maximum, preferred; } VPhoneFrameRateRange;

@interface VPhoneInnerPanelRefresh : NSObject
@end

@implementation VPhoneInnerPanelRefresh
- (void)refresh:(id)link {
    if (vpInnerPanelRendering) return;
    vpInnerPanelRendering = YES;
    int next = (vpInnerPanelShown + 1) % 3;
    void *surface = vpInnerPanelSurfaces[next];
    id image = vpInnerPanelImage;
    dispatch_async(vpInnerPanelQueue, ^{
        vpRenderDisplay(0, (__bridge CFStringRef)vpInnerDisplayName, surface, 0, 0);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (image == vpInnerPanelImage) {
                vpInnerPanelShown = next;
                Class transaction = objc_getClass("CATransaction");
                ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("begin"));
                ((void (*)(id, SEL, BOOL))objc_msgSend)(transaction, sel_registerName("setDisableActions:"), YES);
                ((void (*)(id, SEL, id))objc_msgSend)(image, sel_registerName("setContents:"), (__bridge id)surface);
                ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("commit"));
            }
            vpInnerPanelRendering = NO;
        });
    });
}
@end

static id vpMainRootSceneWindow(void) {
    NSArray *windows = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(objc_getClass("UIWindow"),
        sel_registerName("allWindowsIncludingInternalWindows:onlyVisibleWindows:"), YES, NO);
    for (id window in windows)
        if ([window isKindOfClass:objc_getClass("UIRootSceneWindow")] &&
            [[vpReadObject(vpReadObject(window, "screen"), "displayIdentity") description] isEqual:@"Main"]) return window;
    return nil;
}

// The inner display's pixels, from its CADisplay.
static CGSize vpInnerDisplayPixels(void) {
    for (id display in vpReadObject(objc_getClass("CADisplay"), "displays") ?: @[])
        if ([[display valueForKey:@"name"] isEqual:vpInnerDisplayName])
            return ((CGRect (*)(id, SEL))objc_msgSend)(display, sel_registerName("bounds")).size;
    return CGSizeZero;
}

// backboardd's context for the inner display's pages, 0 for none.
static uint32_t vpInnerPagesContext(void) {
    int token;
    uint64_t state = 0;
    if (notify_register_check(vpInnerPagesNotification, &token) != NOTIFY_STATUS_OK) return 0;
    notify_get_state(token, &state);
    notify_cancel(token);
    return (uint32_t)state;
}

static void vpReleaseInnerPanelSurfaces(void) {
    for (int index = 0; index < 3; index++) {
        if (vpInnerPanelSurfaces[index]) CFRelease(vpInnerPanelSurfaces[index]);
        vpInnerPanelSurfaces[index] = NULL;
    }
}

// MARK: - hand-over hold

// Mirror valid native frames before the swap, retaining the last one across
// a black gap. A separate displayable context survives native scene hiding.
// Render only native displayable roots, with this context excluded; hosted
// windows retain their parents' visibility. After the native mode changes,
// release after two nonblack probes, with a 2 s content deadline. The outer
// 12 s deadline covers the public 10 s sweep and 2 s for arriving content.
// Panel-off/screen blanking still releases immediately.
static id vpPanelHold, vpPanelHoldContext, vpPanelHoldInnerHost;
static NSString *vpPanelHoldDisplayName;
static uint32_t vpPanelHoldDisplayId;
static BOOL (*vpRenderDisplayClients)(mach_port_t, CFStringRef, uint32_t, const uint32_t *, void *, int32_t, int32_t);
static void *vpPanelHoldSurface, *vpPanelHoldVeilSurface, *vpPanelHoldProbes[3];
static int vpPanelHoldProbeShown = -1;
static double vpPanelHoldSince;
static dispatch_source_t vpPanelHoldWatch;
static dispatch_queue_t vpPanelHoldProbeQueue;
static NSData *vpPanelHoldClients;
static NSData *vpPanelHoldFallbackClients;
static BOOL vpPanelHoldSwapped, vpPanelHoldInnerHostActive;
static os_unfair_lock vpPanelHoldLock = OS_UNFAIR_LOCK_INIT;
static unsigned vpPanelHoldReadyFrames;
static BOOL vpPanelHoldAwaitingChange;
static unsigned long vpPanelHoldTargetEpoch;

static void *vpCreatePanelSurface(CGSize pixels) {
    static void *(*createSurface)(CFDictionaryRef);
    if (!createSurface)
        createSurface = dlsym(dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW), "IOSurfaceCreate");
    if (!createSurface || pixels.width < 1 || pixels.height < 1) return NULL;
    NSDictionary *properties = @{@"IOSurfaceWidth": @(pixels.width), @"IOSurfaceHeight": @(pixels.height),
        @"IOSurfaceBytesPerElement": @4, @"IOSurfacePixelFormat": @((uint32_t)'BGRA')};
    return createSurface((__bridge CFDictionaryRef)properties);
}

// Whether a rendered BGRA surface shows anything but black, from an 8x8 grid
// of samples. Runs on the render queue.
static BOOL vpSurfaceHasContent(void *surface) {
    static int (*lock)(void *, uint32_t, uint32_t *), (*unlock)(void *, uint32_t, uint32_t *);
    static void *(*base)(void *);
    static size_t (*width)(void *), (*height)(void *), (*bytesPerRow)(void *);
    if (!lock) {
        void *library = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
        unlock = dlsym(library, "IOSurfaceUnlock");
        base = dlsym(library, "IOSurfaceGetBaseAddress");
        width = dlsym(library, "IOSurfaceGetWidth");
        height = dlsym(library, "IOSurfaceGetHeight");
        bytesPerRow = dlsym(library, "IOSurfaceGetBytesPerRow");
        lock = dlsym(library, "IOSurfaceLock");
    }
    if (!surface || !lock || !unlock || !base || !width || !height || !bytesPerRow) return NO;
    if (lock(surface, 1 /* read-only */, NULL) != 0) return NO;
    const uint8_t *pixels = base(surface);
    size_t w = width(surface), h = height(surface), row = bytesPerRow(surface);
    BOOL content = NO;
    for (int y = 0; pixels && y < 8 && !content; y++)
        for (int x = 0; x < 8 && !content; x++) {
            const uint8_t *pixel = pixels + (h * (2 * y + 1) / 16) * row + (w * (2 * x + 1) / 16) * 4;
            content = pixel[0] > 24 || pixel[1] > 24 || pixel[2] > 24;
        }
    unlock(surface, 1, NULL);
    return content;
}

static void vpReleasePanelHold(NSString *reason) {
    os_unfair_lock_lock(&vpPanelHoldLock);
    if (vpPanelHoldWatch) {
        dispatch_source_cancel(vpPanelHoldWatch);
        vpPanelHoldWatch = nil;
    }
    if (!vpPanelHold) {
        os_unfair_lock_unlock(&vpPanelHoldLock);
        return;
    }
    id hold = vpPanelHold;
    id context = vpPanelHoldContext;
    unsigned long generation = vpPanelHoldGeneration;
    vpPanelHold = nil;
    vpPanelHoldGeneration++;
    // The render server may still show the old contents for this commit, and
    // a probe render may still be running into its surface.
    void *surface = vpPanelHoldSurface;
    void *veilSurface = vpPanelHoldVeilSurface;
    void *probe0 = vpPanelHoldProbes[0], *probe1 = vpPanelHoldProbes[1], *probe2 = vpPanelHoldProbes[2];
    vpPanelHoldSurface = NULL;
    vpPanelHoldVeilSurface = NULL;
    memset(vpPanelHoldProbes, 0, sizeof(vpPanelHoldProbes));
    vpPanelHoldProbeShown = -1;
    vpPanelHoldClients = nil;
    vpPanelHoldFallbackClients = nil;
    vpPanelHoldInnerHostActive = NO;
    vpPanelHoldSwapped = NO;
    os_unfair_lock_unlock(&vpPanelHoldLock);
    vpPanelHoldInnerHost = nil;
    if (vpFoldTraceEnabled()) vpFoldTrace(@"hold_off_request", NULL, hold,
        @{@"generation": @(generation), @"reason": reason, @"owner": @(vpInnerOwnedPanel)});
    Class transaction = objc_getClass("CATransaction");
    ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("begin"));
    ((void (*)(id, SEL, BOOL))objc_msgSend)(transaction, sel_registerName("setDisableActions:"), YES);
    ((void (*)(id, SEL, id))objc_msgSend)(context, sel_registerName("setLayer:"), nil);
    ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("commit"));
    dispatch_queue_t queue = vpPanelHoldProbeQueue ?: vpInnerPanelQueue;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (surface) CFRelease(surface);
        if (veilSurface) CFRelease(veilSurface);
        if (queue) dispatch_async(queue, ^{
            if (probe0) CFRelease(probe0);
            if (probe1) CFRelease(probe1);
            if (probe2) CFRelease(probe2);
        });
    });
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: hold off (%@) after %.0f ms",
        reason, (NSDate.date.timeIntervalSince1970 - vpPanelHoldSince) * 1000]);
}

static void vpReleasePanelHoldAfter(double seconds, NSString *reason) {
    unsigned long generation = vpPanelHoldGeneration;
    unsigned long epoch = vpPanelHoldTargetEpoch;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation == vpPanelHoldGeneration && epoch == vpPanelHoldTargetEpoch) vpReleasePanelHold(reason);
    });
}

// The render server fills in a new context's display binding asynchronously.
// Prepare an empty context before any fold, and admit it only after readback
// matches Main. Keeping it between holds also keeps probes independent of it.
static BOOL vpPreparePanelHoldContext(void) {
    if (vpPanelHoldContext) return ((uint32_t (*)(id, SEL))objc_msgSend)(vpPanelHoldContext, sel_registerName("displayId")) == vpPanelHoldDisplayId;
    id rootWindow = vpMainRootSceneWindow();
    id main = vpReadObject(objc_getClass("CADisplay"), "mainDisplay");
    NSString *name = [main valueForKey:@"name"];
    if (!rootWindow || !name) return NO;
    Class contextClass = objc_getClass("CAContext");
    Method create = class_getClassMethod(contextClass, sel_registerName("remoteContextWithOptions:"));
    Method level = class_getInstanceMethod(contextClass, sel_registerName("setLevel:"));
    Method getLevel = class_getInstanceMethod(contextClass, sel_registerName("level"));
    Method getDisplay = class_getInstanceMethod(contextClass, sel_registerName("displayId"));
    Method getID = class_getInstanceMethod(contextClass, sel_registerName("contextId"));
    Method all = class_getClassMethod(contextClass, sel_registerName("allContexts"));
    CFStringRef *displayKey = dlsym(RTLD_DEFAULT, "kCAContextDisplayId");
    CFStringRef *nameKey = dlsym(RTLD_DEFAULT, "kCAContextDisplayName");
    CFStringRef *displayableKey = dlsym(RTLD_DEFAULT, "kCAContextDisplayable");
    CFStringRef *hitTestKey = dlsym(RTLD_DEFAULT, "kCAContextIgnoresHitTest");
    vpRenderDisplayClients = dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplayClientList");
    if (!create || strcmp(method_getTypeEncoding(create), "@24@0:8@16") ||
        !level || strcmp(method_getTypeEncoding(level), "v20@0:8f16") ||
        !getLevel || strcmp(method_getTypeEncoding(getLevel), "f16@0:8") ||
        !getDisplay || strcmp(method_getTypeEncoding(getDisplay), "I16@0:8") ||
        !getID || strcmp(method_getTypeEncoding(getID), "I16@0:8") ||
        !all || strcmp(method_getTypeEncoding(all), "@16@0:8") ||
        !displayKey || !nameKey || !displayableKey || !hitTestKey || !vpRenderDisplayClients) {
        vpFoldDisplayLog(@"inner display: independent hold context ABI unavailable");
        return NO;
    }
    id mainContext = vpReadObject(vpReadObject(rootWindow, "layer"), "context");
    if (!mainContext) return NO;
    uint32_t displayId = ((uint32_t (*)(id, SEL))objc_msgSend)(mainContext, sel_registerName("displayId"));
    NSMutableDictionary *options = [vpReadObject(mainContext, "options") mutableCopy] ?: [NSMutableDictionary dictionary];
    options[(__bridge NSString *)*nameKey] = name;
    options[(__bridge NSString *)*displayableKey] = @YES;
    options[(__bridge NSString *)*hitTestKey] = @YES;
    id context = ((id (*)(id, SEL, id))objc_msgSend)(contextClass, sel_registerName("remoteContextWithOptions:"), options);
    if (!context) return NO;
    vpPanelHoldContext = context;
    vpPanelHoldDisplayName = name;
    vpPanelHoldDisplayId = displayId;
    return ((uint32_t (*)(id, SEL))objc_msgSend)(context, sel_registerName("displayId")) == displayId;
}

static void vpPrewarmPanelHoldContext(unsigned attempt) {
    @try { if (vpPreparePanelHoldContext()) return; }
    @catch (__unused NSException *exception) {}
    if (attempt < 100) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{ vpPrewarmPanelHoldContext(attempt + 1); });
    else vpFoldDisplayLog(@"inner display: independent hold context unavailable at startup");
}

static void vpHoldPanel(void) {
    if (vpPanelHold) return;
    @try {
        if (!vpPreparePanelHoldContext()) return;
        id rootWindow = vpMainRootSceneWindow();
        id main = vpReadObject(objc_getClass("CADisplay"), "mainDisplay");
        NSString *name = [main valueForKey:@"name"];
        CGSize pixels = main ? ((CGRect (*)(id, SEL))objc_msgSend)(main, sel_registerName("bounds")).size : CGSizeZero;
        if (!vpRenderDisplay) vpRenderDisplay = dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        void *surface = vpCreatePanelSurface(pixels);
        if (!rootWindow || !name || !surface || !vpRenderDisplay) {
            if (surface) CFRelease(surface);
            vpFoldDisplayLog([NSString stringWithFormat:@"inner display: hold unavailable root=%@ main=%@", rootWindow, name]);
            return;
        }
        if (!vpInnerPanelQueue) vpInnerPanelQueue = dispatch_queue_create("com.vphone.folddisplay.inner-panel", DISPATCH_QUEUE_SERIAL);
        double start = NSDate.date.timeIntervalSince1970;
        double renderStart = NSProcessInfo.processInfo.systemUptime;
        vpRenderDisplay(0, (__bridge CFStringRef)name, surface, 0, 0);
        if (vpFoldTraceEnabled()) vpFoldTrace(@"hold_source", surface, nil, @{@"generation": @(vpPanelHoldGeneration + 1), @"display": name,
            @"render_start_uptime": @(renderStart), @"render_end_uptime": @(NSProcessInfo.processInfo.systemUptime)});
        id context = vpPanelHoldContext;
        uint32_t displayId = vpPanelHoldDisplayId;
        Class contextClass = objc_getClass("CAContext");
        float top = 0;
        for (id context in vpReadObject(contextClass, "allContexts")) {
            if (context == vpPanelHoldContext || ((uint32_t (*)(id, SEL))objc_msgSend)(context, sel_registerName("displayId")) != displayId) continue;
            float candidate = ((float (*)(id, SEL))objc_msgSend)(context, sel_registerName("level"));
            if (isfinite(candidate) && candidate > top) top = candidate;
        }
        id hold = [objc_getClass("CALayer") new];
        ((void (*)(id, SEL, CGRect))objc_msgSend)(hold, sel_registerName("setFrame:"), (CGRect){CGPointZero, pixels});
        Class transaction = objc_getClass("CATransaction");
        ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("begin"));
        ((void (*)(id, SEL, BOOL))objc_msgSend)(transaction, sel_registerName("setDisableActions:"), YES);
        ((void (*)(id, SEL, id))objc_msgSend)(hold, sel_registerName("setContents:"), (__bridge id)surface);
        ((void (*)(id, SEL, float))objc_msgSend)(context, sel_registerName("setLevel:"), nextafterf(top, INFINITY));
        ((void (*)(id, SEL, id))objc_msgSend)(context, sel_registerName("setLayer:"), hold);
        ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("commit"));
        vpPanelHold = hold;
        vpPanelHoldContext = context;
        vpPanelHoldDisplayName = name;
        vpPanelHoldDisplayId = displayId;
        vpPanelHoldReadyFrames = 0;
        vpPanelHoldAwaitingChange = YES;
        vpPanelHoldUsesNativeLifecycle = NO;
        vpPanelHoldSwapped = NO;
        vpPanelHoldTargetEpoch++;
        vpPanelHoldSurface = surface;
        vpPanelHoldSince = NSDate.date.timeIntervalSince1970;
        unsigned long generation = ++vpPanelHoldGeneration;
        if (vpFoldTraceEnabled()) vpFoldTrace(@"hold_on_commit", NULL, nil, @{@"generation": @(generation), @"owner": @(vpInnerOwnedPanel)});
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: hold on (%@ rendered in %.0f ms)",
            name, (vpPanelHoldSince - start) * 1000]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation == vpPanelHoldGeneration) vpReleasePanelHold(@"timeout");
        });
    } @catch (NSException *exception) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: hold exception %@", exception.reason]);
    }
}

static NSData *vpCollectCoverFallbackClients(uint32_t displayId) {
    id cover = vpSpringBoardWindowScene(NO);
    SEL windowsSel = sel_registerName("windows");
    if (!cover || ![cover respondsToSelector:windowsSel]) return nil;
    static NSSet *allowed;
    if (!allowed) allowed = [NSSet setWithObjects:
        @"_SBWallpaperSecureWindow", @"SBHomeScreenWindow", @"SBFloatingDockWindow",
        @"SBFolderWindow", @"SBStatusBarWindow", nil];
    struct VPFallbackClient { uint32_t cid; float level; } items[32];
    size_t count = 0;
    SEL hiddenSel = sel_registerName("isHidden");
    SEL idSel = sel_registerName("contextId");
    SEL displaySel = sel_registerName("displayId");
    SEL levelSel = sel_registerName("level");
    for (id window in ((id (*)(id, SEL))objc_msgSend)(cover, windowsSel)) {
        if (![allowed containsObject:NSStringFromClass([window class])]) continue;
        if ([window respondsToSelector:hiddenSel] && ((BOOL (*)(id, SEL))objc_msgSend)(window, hiddenSel)) continue;
        id context = vpReadObject(vpReadObject(window, "layer"), "context");
        if (!context) continue;
        uint32_t cid = ((uint32_t (*)(id, SEL))objc_msgSend)(context, idSel);
        if (!cid || ((uint32_t (*)(id, SEL))objc_msgSend)(context, displaySel) != displayId) continue;
        float level = ((float (*)(id, SEL))objc_msgSend)(context, levelSel);
        if (!isfinite(level)) level = 0;
        if (count < sizeof(items) / sizeof(items[0])) items[count++] = (struct VPFallbackClient){cid, level};
    }
    if (!count) return nil;
    for (size_t i = 1; i < count; i++) {
        struct VPFallbackClient key = items[i];
        size_t j = i;
        while (j > 0 && items[j - 1].level > key.level) {
            items[j] = items[j - 1];
            j--;
        }
        items[j] = key;
    }
    NSMutableData *data = [NSMutableData dataWithCapacity:count * sizeof(uint32_t)];
    for (size_t i = 0; i < count; i++) [data appendBytes:&items[i].cid length:sizeof(uint32_t)];
    return [data copy];
}

static void vpRefreshPanelHoldClients(void) {
    if (!vpPanelHoldContext) return;
    NSMutableData *clients = [NSMutableData data];
    uint32_t holdIdentifier = ((uint32_t (*)(id, SEL))objc_msgSend)(vpPanelHoldContext, sel_registerName("contextId"));
    CFStringRef *nameKey = dlsym(RTLD_DEFAULT, "kCAContextDisplayName");
    CFStringRef *displayableKey = dlsym(RTLD_DEFAULT, "kCAContextDisplayable");
    for (id context in vpReadObject(objc_getClass("CAContext"), "allContexts")) {
        uint32_t identifier = ((uint32_t (*)(id, SEL))objc_msgSend)(context, sel_registerName("contextId"));
        NSDictionary *options = vpReadObject(context, "options");
        // Hosted window contexts are drawn by their displayable parent.
        // Rendering them directly bypasses that parent's visibility.
        if (!displayableKey || ![options[(__bridge NSString *)*displayableKey] boolValue]) continue;
        NSString *name = nameKey ? options[(__bridge NSString *)*nameKey] : nil;
        if (identifier == holdIdentifier || (name && ![name isEqual:vpPanelHoldDisplayName]) ||
            ((uint32_t (*)(id, SEL))objc_msgSend)(context, sel_registerName("displayId")) != vpPanelHoldDisplayId) continue;
        if (identifier) [clients appendBytes:&identifier length:sizeof(identifier)];
    }
    BOOL postSwapAwaiting = vpPanelHoldSwapped && vpPanelHoldAwaitingChange && vpPanelAwakeFoldEligible();
    NSData *fallbackClients = (postSwapAwaiting && !vpInnerOwnedPanel)
        ? vpCollectCoverFallbackClients(vpPanelHoldDisplayId) : nil;
    os_unfair_lock_lock(&vpPanelHoldLock);
    vpPanelHoldClients = [clients copy];
    vpPanelHoldFallbackClients = fallbackClients;
    os_unfair_lock_unlock(&vpPanelHoldLock);
}

// Render the native physical panel without the hold, for either direction.
static void vpWatchNativePanelContent(void) {
    if (!vpPanelHold) return;
    vpRefreshPanelHoldClients();
    if (vpPanelHoldWatch) return;
    if (!vpPanelHoldProbes[0]) {
        id main = vpReadObject(objc_getClass("CADisplay"), "mainDisplay");
        CGSize pixels = ((CGRect (*)(id, SEL))objc_msgSend)(main, sel_registerName("bounds")).size;
        for (int index = 0; index < 3; index++) vpPanelHoldProbes[index] = vpCreatePanelSurface(pixels);
        vpPanelHoldVeilSurface = vpCreatePanelSurface(pixels);
    }
    if (!vpPanelHoldProbes[0] || !vpPanelHoldProbes[1] || !vpPanelHoldProbes[2] || !vpPanelHoldVeilSurface || !vpRenderDisplay) {
        vpReleasePanelHold(@"inner display not observable");
        return;
    }
    if (!vpPanelHoldProbeQueue) {
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        vpPanelHoldProbeQueue = dispatch_queue_create("com.vphone.folddisplay.panel-probe", attr);
    }
    unsigned long generation = vpPanelHoldGeneration;
    os_unfair_lock_lock(&vpPanelHoldLock);
    vpPanelHoldWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, vpPanelHoldProbeQueue);
    dispatch_source_t watch = vpPanelHoldWatch;
    os_unfair_lock_unlock(&vpPanelHoldLock);
    dispatch_source_set_timer(watch, DISPATCH_TIME_NOW, NSEC_PER_SEC / 60, NSEC_PER_SEC / 240);
    dispatch_source_set_event_handler(watch, ^{
        os_unfair_lock_lock(&vpPanelHoldLock);
        if (generation != vpPanelHoldGeneration || vpPanelHoldWatch != watch || !vpPanelHold) {
            os_unfair_lock_unlock(&vpPanelHoldLock);
            return;
        }
        int next = (vpPanelHoldProbeShown + 1) % 3;
        void *probe = vpPanelHoldProbes[next];
        unsigned long epoch = vpPanelHoldTargetEpoch;
        NSData *clients = vpPanelHoldClients;
        NSData *fallbackClients = vpPanelHoldFallbackClients;
        BOOL innerHostWaiting = vpPanelHoldInnerHostActive && vpPanelHoldAwaitingChange;
        NSString *displayName = vpPanelHoldDisplayName;
        if (!probe || innerHostWaiting) {
            os_unfair_lock_unlock(&vpPanelHoldLock);
            return;
        }
        CFRetain(probe);
        os_unfair_lock_unlock(&vpPanelHoldLock);

        BOOL rendered = clients.length && vpRenderDisplayClients(0, (__bridge CFStringRef)displayName,
            (uint32_t)(clients.length / sizeof(uint32_t)), clients.bytes, probe, 0, 0);
        BOOL drawn = rendered && vpSurfaceHasContent(probe);
        if (!drawn && fallbackClients.length) {
            rendered = vpRenderDisplayClients(0, (__bridge CFStringRef)displayName,
                (uint32_t)(fallbackClients.length / sizeof(uint32_t)), fallbackClients.bytes, probe, 0, 0);
            drawn = rendered && vpSurfaceHasContent(probe);
        }

        os_unfair_lock_lock(&vpPanelHoldLock);
        BOOL accepted = (generation == vpPanelHoldGeneration && vpPanelHoldWatch == watch && vpPanelHold && epoch == vpPanelHoldTargetEpoch);
        BOOL awaitingChange = vpPanelHoldAwaitingChange;
        BOOL releaseAfter = NO;
        unsigned long releaseEpoch = 0;
        if (accepted) {
            if (drawn) {
                Class transaction = objc_getClass("CATransaction");
                ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("begin"));
                ((void (*)(id, SEL, BOOL))objc_msgSend)(transaction, sel_registerName("setDisableActions:"), YES);
                ((void (*)(id, SEL, id))objc_msgSend)(vpPanelHold, sel_registerName("setContents:"), (__bridge id)probe);
                ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("commit"));
                ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("flush"));
                vpPanelHoldProbeShown = next;
            }
            if (awaitingChange) {
                vpPanelHoldReadyFrames = 0;
            } else {
                vpPanelHoldReadyFrames = drawn ? vpPanelHoldReadyFrames + 1 : 0;
                if (vpPanelHoldReadyFrames >= 2) {
                    dispatch_source_cancel(watch);
                    vpPanelHoldWatch = nil;
                    releaseAfter = YES;
                    releaseEpoch = epoch;
                }
            }
        }
        os_unfair_lock_unlock(&vpPanelHoldLock);
        if (accepted && drawn && vpFoldTraceEnabled()) vpFoldTrace(awaitingChange ? @"hold_frame_update" : @"target_content_detected", probe, nil,
            @{@"generation": @(generation), @"display": displayName, @"client_count": @(clients.length / sizeof(uint32_t))});
        CFRelease(probe);
        if (releaseAfter) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation == vpPanelHoldGeneration && releaseEpoch == vpPanelHoldTargetEpoch)
                    vpReleasePanelHoldAfter(1.0 / 30, @"native panel content drawn");
            });
        }
    });
    dispatch_resume(watch);
}

// On close, cover's auxiliary overlay stays opaque black until reveal (~200 ms after swap).
// Hide it without animation while awake cover ownership activates, and unhide on open
// or panel-off transitions so SpringBoard's open dimming remains intact.
static void vpSetCoverAuxiliaryHidden(BOOL hidden) {
    if (hidden && !vpPanelAwakeFoldEligible()) return;
    Class auxClass = objc_getClass("SBWindowSceneAuxiliaryContentWindow");
    id cover = vpSpringBoardWindowScene(NO);
    SEL windowsSel = sel_registerName("windows");
    if (!auxClass || !cover || ![cover respondsToSelector:windowsSel]) return;
    void (^apply)(void) = ^{
        Class transaction = objc_getClass("CATransaction");
        if (transaction) {
            ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("begin"));
            ((void (*)(id, SEL, BOOL))objc_msgSend)(transaction, sel_registerName("setDisableActions:"), YES);
        }
        for (id window in ((id (*)(id, SEL))objc_msgSend)(cover, windowsSel)) {
            if (![window isKindOfClass:auxClass]) continue;
            ((void (*)(id, SEL, BOOL))objc_msgSend)(window, sel_registerName("setHidden:"), hidden);
            id layer = vpReadObject(window, "layer");
            if (layer) {
                ((void (*)(id, SEL))objc_msgSend)(layer, sel_registerName("removeAllAnimations"));
                if (hidden) ((void (*)(id, SEL, float))objc_msgSend)(layer, sel_registerName("setOpacity:"), 0.0f);
            }
        }
        if (transaction) {
            ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("commit"));
            if (objc_getClass("UIView")) ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("flush"));
        }
    };
    Class uiView = objc_getClass("UIView");
    SEL withoutAnim = sel_registerName("performWithoutAnimation:");
    if (uiView && [uiView respondsToSelector:withoutAnim]) {
        ((void (*)(id, SEL, void (^)(void)))objc_msgSend)(uiView, withoutAnim, apply);
    } else {
        apply();
    }
}

static void vpClearPanelHoldVeils(id hold) {
    os_unfair_lock_lock(&vpPanelHoldLock);
    vpPanelHoldInnerHostActive = NO;
    os_unfair_lock_unlock(&vpPanelHoldLock);
    vpPanelHoldInnerHost = nil;
    if (!hold || ![hold respondsToSelector:sel_registerName("sublayers")]) return;
    NSArray *sublayers = ((id (*)(id, SEL))objc_msgSend)(hold, sel_registerName("sublayers"));
    if (!sublayers.count) return;
    Class transaction = objc_getClass("CATransaction");
    if (!transaction) return;
    ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("begin"));
    ((void (*)(id, SEL, BOOL))objc_msgSend)(transaction, sel_registerName("setDisableActions:"), YES);
    for (id sub in [sublayers copy]) ((void (*)(id, SEL))objc_msgSend)(sub, sel_registerName("removeFromSuperlayer"));
    ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("commit"));
}

static void vpAttachInnerHoldHost(id hold) {
    uint32_t hosted = vpInnerPagesContext();
    Class hostClass = objc_getClass("CALayerHost");
    CGSize innerPixels = vpInnerDisplayPixels();
    if (!hold || !hosted || !hostClass || innerPixels.width < 1 || innerPixels.height < 1 ||
        ![hold respondsToSelector:sel_registerName("bounds")] ||
        ![hold respondsToSelector:sel_registerName("insertSublayer:atIndex:")]) return;
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(hold, sel_registerName("bounds"));
    if (bounds.size.width < 1 || bounds.size.height < 1) return;
    BOOL turned = innerPixels.width > innerPixels.height;
    CGSize upright = turned ? CGSizeMake(innerPixels.height, innerPixels.width) : innerPixels;
    CGAffineTransform transform = CGAffineTransformConcat(
        turned ? CGAffineTransformMakeRotation(-M_PI_2) : CGAffineTransformIdentity,
        CGAffineTransformMakeScale(bounds.size.width / upright.width, bounds.size.height / upright.height));
    Class transaction = objc_getClass("CATransaction");
    if (transaction) {
        ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("begin"));
        ((void (*)(id, SEL, BOOL))objc_msgSend)(transaction, sel_registerName("setDisableActions:"), YES);
    }
    if (vpPanelHoldInnerHost) ((void (*)(id, SEL))objc_msgSend)(vpPanelHoldInnerHost, sel_registerName("removeFromSuperlayer"));
    id host = [hostClass new];
    ((void (*)(id, SEL, uint32_t))objc_msgSend)(host, sel_registerName("setContextId:"), hosted);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(host, sel_registerName("setBounds:"), (CGRect){CGPointZero, innerPixels});
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(host, sel_registerName("setPosition:"), CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds)));
    ((void (*)(id, SEL, CGAffineTransform))objc_msgSend)(host, sel_registerName("setAffineTransform:"), transform);
    ((void (*)(id, SEL, id, unsigned))objc_msgSend)(hold, sel_registerName("insertSublayer:atIndex:"), host, 0);
    if (transaction) {
        ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("commit"));
        if (objc_getClass("UIView")) ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("flush"));
    }
    vpPanelHoldInnerHost = host;
    os_unfair_lock_lock(&vpPanelHoldLock);
    vpPanelHoldInnerHostActive = YES;
    os_unfair_lock_unlock(&vpPanelHoldLock);
}

// Keep an unshared departing IOSurface in a child veil layer while probes (or the hosted
// inner context) update underneath, crossfading across [swap .. didChange].
static void vpCrossfadePanelHoldSwap(BOOL innerOwns) {
    id hold = nil;
    void *departing = NULL;
    os_unfair_lock_lock(&vpPanelHoldLock);
    hold = vpPanelHold;
    if (hold && vpPanelHoldAwaitingChange && vpPanelAwakeFoldEligible() && (!innerOwns || vpInnerPagesContext())) {
        if (!innerOwns && vpPanelHoldProbeShown >= 0 && vpPanelHoldProbeShown < 3 &&
            vpPanelHoldVeilSurface && vpPanelHoldProbes[vpPanelHoldProbeShown]) {
            departing = vpPanelHoldProbes[vpPanelHoldProbeShown];
            vpPanelHoldProbes[vpPanelHoldProbeShown] = vpPanelHoldVeilSurface;
            vpPanelHoldVeilSurface = departing;
        } else {
            departing = vpPanelHoldSurface;
        }
    }
    if (departing) CFRetain(departing);
    os_unfair_lock_unlock(&vpPanelHoldLock);
    vpClearPanelHoldVeils(hold);
    if (!hold || !departing) {
        if (departing) CFRelease(departing);
        return;
    }
    if (innerOwns) vpAttachInnerHoldHost(hold);
    Class layerClass = objc_getClass("CALayer");
    Class animationClass = objc_getClass("CABasicAnimation");
    Class transaction = objc_getClass("CATransaction");
    if (layerClass && animationClass && transaction &&
        [hold respondsToSelector:sel_registerName("bounds")] &&
        [hold respondsToSelector:sel_registerName("addSublayer:")]) {
        CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(hold, sel_registerName("bounds"));
        id veil = [layerClass new];
        ((void (*)(id, SEL, CGRect))objc_msgSend)(veil, sel_registerName("setFrame:"), bounds);
        ((void (*)(id, SEL, id))objc_msgSend)(veil, sel_registerName("setContents:"), (__bridge id)departing);
        ((void (*)(id, SEL, float))objc_msgSend)(veil, sel_registerName("setOpacity:"), 0.0f);
        id anim = ((id (*)(id, SEL, id))objc_msgSend)(animationClass, sel_registerName("animationWithKeyPath:"), @"opacity");
        ((void (*)(id, SEL, id))objc_msgSend)(anim, sel_registerName("setFromValue:"), @1.0);
        ((void (*)(id, SEL, id))objc_msgSend)(anim, sel_registerName("setToValue:"), @0.0);
        ((void (*)(id, SEL, double))objc_msgSend)(anim, sel_registerName("setDuration:"), innerOwns ? 0.30 : 0.24);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(anim, sel_registerName("setRemovedOnCompletion:"), YES);
        ((void (*)(id, SEL, id))objc_msgSend)(anim, sel_registerName("setFillMode:"), @"backwards");
        ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("begin"));
        ((void (*)(id, SEL, BOOL))objc_msgSend)(transaction, sel_registerName("setDisableActions:"), YES);
        ((void (*)(id, SEL, id))objc_msgSend)(hold, sel_registerName("addSublayer:"), veil);
        ((void (*)(id, SEL, id, id))objc_msgSend)(veil, sel_registerName("addAnimation:forKey:"), anim, @"vpCloseDissolve");
        ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("commit"));
        if (objc_getClass("UIView")) ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("flush"));
        if (vpFoldTraceEnabled()) vpFoldTrace(@"hold_close_dissolve", departing, nil, @{@"generation": @(vpPanelHoldGeneration)});
    }
    CFRelease(departing);
}

static void vpPanelHoldFollowOwner(BOOL innerOwns) {
    vpSetCoverAuxiliaryHidden(!innerOwns);
    if (!vpPanelHold) return;
    os_unfair_lock_lock(&vpPanelHoldLock);
    if (!vpPanelHoldUsesNativeLifecycle) vpPanelHoldAwaitingChange = NO;
    vpPanelHoldSwapped = YES;
    vpPanelHoldReadyFrames = 0;
    vpPanelHoldTargetEpoch++;
    os_unfair_lock_unlock(&vpPanelHoldLock);
    vpCrossfadePanelHoldSwap(innerOwns);
    if (!vpPanelHoldUsesNativeLifecycle) vpReleasePanelHoldAfter(2.0, @"native content timeout");
    if (vpFoldTraceEnabled()) vpFoldTrace(@"hold_follow_owner", NULL, nil, @{@"generation": @(vpPanelHoldGeneration), @"inner_owns": @(innerOwns)});
    vpWatchNativePanelContent();
}

static void vpNativeContentModeDidChange(unsigned long generation, BOOL finished) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ vpNativeContentModeDidChange(generation, finished); });
        return;
    }
    vpApplyPanelStates(nil, nil);
    if (vpPanelHold && generation == vpPanelHoldGeneration) {
        os_unfair_lock_lock(&vpPanelHoldLock);
        if (vpPanelHold && generation == vpPanelHoldGeneration) {
            if (finished) vpPanelHoldAwaitingChange = NO;
            vpPanelHoldReadyFrames = 0;
            vpPanelHoldTargetEpoch++;
        }
        os_unfair_lock_unlock(&vpPanelHoldLock);
        if (finished) vpReleasePanelHoldAfter(2.0, @"native content timeout");
        vpWatchNativePanelContent();
    }
    if (vpFoldTraceEnabled()) vpFoldTrace(finished ? @"native_mode_postflight" : @"native_mode_did_change", NULL, nil, @{@"owner": @(vpInnerOwnedPanel)});
}

static void vpShowInnerDisplay(BOOL shown) {
    @try {
        if (!shown) {
            if (!vpInnerPanelRoot) return;
            ((void (*)(id, SEL))objc_msgSend)(vpInnerPanelRefresh, sel_registerName("invalidate"));
            vpInnerPanelRefresh = nil;
            ((void (*)(id, SEL))objc_msgSend)(vpInnerPanelRoot, sel_registerName("removeFromSuperlayer"));
            vpInnerPanelRoot = vpInnerPanelImage = nil;
            // A render still running finishes into its surface first.
            dispatch_async(vpInnerPanelQueue, ^{ dispatch_async(dispatch_get_main_queue(), ^{
                if (!vpInnerPanelRoot) vpReleaseInnerPanelSurfaces();
            }); });
            vpFoldDisplayLog(@"inner display: shown=0");
            return;
        }
        if (vpInnerPanelRoot) return;
        uint32_t hosted = vpInnerPagesContext();
        id rootWindow = vpMainRootSceneWindow();
        CGSize pixels = vpInnerDisplayPixels();
        void *(*createSurface)(CFDictionaryRef) =
            dlsym(dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW), "IOSurfaceCreate");
        if (!vpRenderDisplay) vpRenderDisplay = dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        if (!rootWindow || pixels.width < 1 || (!hosted && (!createSurface || !vpRenderDisplay))) {
            vpFoldDisplayLog([NSString stringWithFormat:@"inner display: show unavailable root=%@ pixels={%.0f, %.0f}",
                rootWindow, pixels.width, pixels.height]);
            return;
        }
        if (!hosted && !vpInnerPanelSurfaces[0]) {
            NSDictionary *properties = @{@"IOSurfaceWidth": @(pixels.width), @"IOSurfaceHeight": @(pixels.height),
                @"IOSurfaceBytesPerElement": @4, @"IOSurfacePixelFormat": @((uint32_t)'BGRA')};
            for (int index = 0; index < 3; index++) vpInnerPanelSurfaces[index] = createSurface((__bridge CFDictionaryRef)properties);
            if (!vpInnerPanelSurfaces[0] || !vpInnerPanelSurfaces[1] || !vpInnerPanelSurfaces[2]) {
                vpReleaseInnerPanelSurfaces();
                vpFoldDisplayLog(@"inner display: surfaces unavailable");
                return;
            }
        }
        if (!vpInnerPanelQueue) vpInnerPanelQueue = dispatch_queue_create("com.vphone.folddisplay.inner-panel", DISPATCH_QUEUE_SERIAL);
        // The inner display is portrait like the panel and fills it as it is
        // (one that read landscape would be turned a quarter, -90 degrees).
        // The panel is the cover's, a little narrower than the inner display
        // (1398x2034 against 2007x2853), so the fill is about 2% tighter
        // across than along; it leaves no bars, and the digitizer, which
        // spans the panel, maps onto the whole inner display as it is.
        id rootLayer = vpReadObject(rootWindow, "layer");
        CGRect panel = ((CGRect (*)(id, SEL))objc_msgSend)(rootLayer, sel_registerName("bounds"));
        CGFloat pointScale = ((double (*)(id, SEL))objc_msgSend)(vpReadObject(rootWindow, "screen"), sel_registerName("scale"));
        CGSize inner = CGSizeMake(pixels.width / pointScale, pixels.height / pointScale);
        BOOL turned = inner.width > inner.height;
        CGSize upright = turned ? CGSizeMake(inner.height, inner.width) : inner;
        CGAffineTransform transform = CGAffineTransformConcat(
            turned ? CGAffineTransformMakeRotation(-M_PI_2) : CGAffineTransformIdentity,
            CGAffineTransformMakeScale(panel.size.width / upright.width, panel.size.height / upright.height));
        // backboardd's layer is in the inner display's pixels.
        if (hosted) transform = CGAffineTransformConcat(CGAffineTransformMakeScale(1 / pointScale, 1 / pointScale), transform);
        id root = [objc_getClass("CALayer") new];
        ((void (*)(id, SEL, CGRect))objc_msgSend)(root, sel_registerName("setFrame:"), panel);
        ((void (*)(id, SEL, CGColorRef))objc_msgSend)(root, sel_registerName("setBackgroundColor:"),
            ((CGColorRef (*)(id, SEL))objc_msgSend)(vpReadObject(objc_getClass("UIColor"), "blackColor"), sel_registerName("CGColor")));
        ((void (*)(id, SEL, double))objc_msgSend)(root, sel_registerName("setZPosition:"), 1.0e9);
        id image = [objc_getClass(hosted ? "CALayerHost" : "CALayer") new];
        if (hosted) ((void (*)(id, SEL, uint32_t))objc_msgSend)(image, sel_registerName("setContextId:"), hosted);
        ((void (*)(id, SEL, CGRect))objc_msgSend)(image, sel_registerName("setBounds:"), (CGRect){CGPointZero, hosted ? pixels : inner});
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(image, sel_registerName("setPosition:"), CGPointMake(CGRectGetMidX(panel), CGRectGetMidY(panel)));
        ((void (*)(id, SEL, CGAffineTransform))objc_msgSend)(image, sel_registerName("setAffineTransform:"), transform);
        ((void (*)(id, SEL, id))objc_msgSend)(root, sel_registerName("addSublayer:"), image);
        ((void (*)(id, SEL, id))objc_msgSend)(rootLayer, sel_registerName("addSublayer:"), root);
        vpInnerPanelRoot = root;
        vpInnerPanelImage = image;
        vpInnerPanelContextId = hosted;
        NSInteger fps = ((NSInteger (*)(id, SEL))objc_msgSend)(vpReadObject(rootWindow, "screen"), sel_registerName("maximumFramesPerSecond"));
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: shown=1 panel={%.0f, %.0f} inner={%.0f, %.0f} turned=%d scale={%.3f, %.3f} fps=%ld context=%u",
            panel.size.width, panel.size.height, inner.width, inner.height, turned,
            panel.size.width / upright.width, panel.size.height / upright.height, (long)fps, hosted]);
        if (hosted) {
            if (vpPanelHold && vpPanelHoldSwapped && vpPanelHoldAwaitingChange && vpInnerOwnedPanel && !vpPanelHoldInnerHostActive) {
                vpAttachInnerHoldHost(vpPanelHold);
            }
            return;
        }
        vpInnerPanelRefresh = ((id (*)(id, SEL, id, SEL))objc_msgSend)(objc_getClass("CADisplayLink"),
            sel_registerName("displayLinkWithTarget:selector:"), [VPhoneInnerPanelRefresh new], @selector(refresh:));
        // The panel shows the inner display at the panel's top rate, asked for
        // rather than left to the system's choice for a link with no range.
        SEL setRange = sel_registerName("setPreferredFrameRateRange:");
        if (fps > 60 && [vpInnerPanelRefresh respondsToSelector:setRange])
            ((void (*)(id, SEL, VPhoneFrameRateRange))objc_msgSend)(vpInnerPanelRefresh, setRange, (VPhoneFrameRateRange){fps, fps, fps});
        ((void (*)(id, SEL, id, id))objc_msgSend)(vpInnerPanelRefresh, sel_registerName("addToRunLoop:forMode:"),
            NSRunLoop.mainRunLoop, NSRunLoopCommonModes);
    } @catch (NSException *exception) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: show exception %@", exception.reason]);
    }
}

// backboardd publishes its context with the inner display's first page,
// which can come after the panel is shown, and takes it back if it cannot
// read a page.
static void vpFollowInnerPages(void) {
    int token;
    notify_register_dispatch(vpInnerPagesNotification, &token, dispatch_get_main_queue(), ^(int unused) {
        if (!vpInnerPanelRoot || vpInnerPagesContext() == vpInnerPanelContextId) return;
        vpShowInnerDisplay(NO);
        vpShowInnerDisplay(YES);
        if (vpPanelHold && vpPanelHoldSwapped && vpPanelHoldAwaitingChange && vpInnerOwnedPanel) vpAttachInnerHoldHost(vpPanelHold);
    });
}

#ifndef VP_PANEL_TEST_SOURCE
#define VP_PANEL_TEST_SOURCE "../FoldDisplay/FoldDisplayPanel.m"
#endif
#import VP_PANEL_TEST_SOURCE
#include <assert.h>

NSString *const vpInnerDisplayName = @"Fixture inner";
const char *const vpInnerPagesNotification = "fixture.pages";
const char *const vpPanelDarkNotification = "fixture.dark";
static BOOL actualInner;
static id fixtureDisplay;
static unsigned offRequests;
static unsigned orientationRefreshes, nativeTransitions;
void vpFoldDisplayLog(NSString *line) { (void)line; }
BOOL vpFoldTraceEnabled(void) { return NO; }
void vpFoldTrace(NSString *event, void *surface, id layer, NSDictionary *fields) { (void)event; (void)surface; (void)layer; (void)fields; }
void vpInstallAlwaysOnWakePolicy(void) {}
void vpRefreshPanelOrientationLock(void) { orientationRefreshes++; }
id vpSpringBoardWindowScene(BOOL inner) { return inner ? @"inner" : @"cover"; }
BOOL vpIsInnerDisplay(id display) { return display == fixtureDisplay; }
static id fixtureCloakView;
id vpReadObjectIvar(id object, const char *name) {
    (void)object;
    return !strcmp(name, "_cloakContentsView") ? fixtureCloakView : nil;
}
id vpReadObject(id object, const char *name) {
    (void)object;
    if (!strcmp(name, "primaryWindowScene")) return vpSpringBoardWindowScene(actualInner);
    if (!strcmp(name, "sharedApplication") || !strcmp(name, "displayContentModeCoordinator")) return @"coordinator";
    if (!strcmp(name, "displays")) return @[fixtureDisplay];
    return nil;
}
@interface FoldCloakView : NSObject
@property(nonatomic, strong) id backgroundColor;
@property(nonatomic, assign) double alpha;
@end
@implementation FoldCloakView
@end
@interface FoldSnapshotTransitionCoordinator : NSObject
@property(nonatomic, copy) void (^preflight)(id);
@property(nonatomic, copy) void (^cloakInstaller)(void);
- (void)addPreflightActionsFromParticipant:(id)participant actions:(void (^)(id))actions;
@end
@implementation FoldSnapshotTransitionCoordinator
- (void)addPreflightActionsFromParticipant:(id)participant actions:(void (^)(id))actions {
    (void)participant; self.preflight = actions;
}
@end
static void originalSnapshotHandleTransition(id self, SEL selector, id coordinator, FoldSnapshotTransitionCoordinator *transitionCoordinator) {
    (void)self; (void)selector; (void)coordinator;
    transitionCoordinator.cloakInstaller = ^{
        ((FoldCloakView *)fixtureCloakView).backgroundColor = @"black";
        ((FoldCloakView *)fixtureCloakView).alpha = 1.0;
    };
}
static BOOL originalDeferEffect(id self, SEL selector, id context) {
    (void)self; (void)selector; (void)context;
    return YES;
}
@interface FoldPowerControl : NSObject {
@public unsigned int _display_id;
}
@end
@implementation FoldPowerControl
@end
@interface FoldModeCoordinator : NSObject
@property(nonatomic, copy) void (^handler)(id, id);
- (void)addDisplayContentModeDidChangeHandlerFromParticipant:(id)participant handler:(void (^)(id, id))handler;
@end
@implementation FoldModeCoordinator
- (void)addDisplayContentModeDidChangeHandlerFromParticipant:(id)participant handler:(void (^)(id, id))handler {
    (void)participant; self.handler=handler;
}
@end
@interface FoldPostflightCoordinator : FoldModeCoordinator
@property(nonatomic, copy) void (^postflight)(id, id);
- (void)addPostflightActionsFromParticipant:(id)participant actions:(void (^)(id, id))actions;
@end
@implementation FoldPostflightCoordinator
- (void)addPostflightActionsFromParticipant:(id)participant actions:(void (^)(id, id))actions {
    (void)participant; self.postflight=actions;
}
@end
static unsigned nativeCompletions;
static void perform(id receiver, SEL selector, FoldModeCoordinator *coordinator) {
    (void)receiver; (void)selector;
    nativeTransitions++;
    assert(orientationRefreshes == nativeTransitions);
    actualInner=NO;
    if (coordinator.handler) { nativeCompletions++; coordinator.handler(nil,nil); }
}
static void apply(id control, SEL selector, long long state, id completion) {
    (void)selector;
    if (control == vpPrimaryStateControl && !state) offRequests++;
    if (completion) ((void (^)(void))completion)();
}
int main(void) { @autoreleasepool {
    fixtureDisplay = @{@"displayId": @7};
    FoldPowerControl *cover=[FoldPowerControl new], *inner=[FoldPowerControl new];
    cover->_display_id=1; inner->_display_id=7;
    vpPrimaryStateControl=cover; vpInnerStateControl=inner;
    vpOriginalTransitionDisplayState=(IMP)apply;
    vpPrimaryWantedState=vpPrimaryAppliedState=1;
    vpInnerWantedState=vpInnerAppliedState=0; vpInnerOwnedPanel=0;
    // Native ownership changes before the power request. No primary-swap
    // observer has run yet, as in the instant transition path on the VM.
    actualInner=YES;
    vpSharedScanoutTransition(cover, sel_registerName("transitionToDisplayState:withCompletion:"), 0, nil);
    assert(vpPrimaryAppliedState==1 && offRequests==0 && vpInnerOwnedPanel==1);
    __block unsigned completed=0;
    vpSharedScanoutTransition(inner, sel_registerName("transitionToDisplayState:withCompletion:"), 1, ^{completed++;});
    assert(vpPrimaryAppliedState==1 && !vpHandoffHeld && completed==1);
    actualInner=NO;
    vpSharedScanoutTransition(inner, sel_registerName("transitionToDisplayState:withCompletion:"), 0, nil);
    assert(vpPrimaryAppliedState==1 && offRequests==0 && vpInnerOwnedPanel==0);
    vpSharedScanoutTransition(cover, sel_registerName("transitionToDisplayState:withCompletion:"), 1, nil);
    assert(vpPrimaryAppliedState==1 && !vpHandoffHeld);
    // A power-off request from the current owner still powers the panel off.
    vpSharedScanoutTransition(cover, sel_registerName("transitionToDisplayState:withCompletion:"), 0, nil);
    assert(vpPrimaryAppliedState==0 && offRequests==1);
    actualInner=YES;
    vpSharedScanoutTransition(cover, sel_registerName("transitionToDisplayState:withCompletion:"), 1, nil);
    assert(vpPrimaryAppliedState==0 && !vpHandoffHeld);
    vpSharedScanoutTransition(inner, sel_registerName("transitionToDisplayState:withCompletion:"), 1, nil);
    assert(vpPrimaryAppliedState==1 && offRequests==1);
    // The Home live path sends a native mode completion without an App swap
    // callback or a new power request. Exercise production registration too.
    FoldModeCoordinator *coordinator=[FoldModeCoordinator new];
    vpOriginalPerformContentModeTransition=(IMP)perform;
    vpFollowContentModeTransition(nil,sel_registerName("performDisplayContentModeTransitionWithCoordinator:"),coordinator);
    assert(coordinator.handler && nativeCompletions==1 && vpInnerOwnedPanel==0 && vpInnerAppliedState==0);
    // A long native transition changes ownership before its postflight. Keep
    // probing until postflight, and ignore completion from an obsolete hold.
    FoldPostflightCoordinator *longTransition=[FoldPostflightCoordinator new];
    vpPanelHold=[NSObject new];
    vpPanelHoldAwaitingChange=YES;
    vpPanelHoldGeneration=41;
    vpPanelHoldWatch=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_resume(vpPanelHoldWatch);
    vpFollowContentModeTransition(nil,sel_registerName("performDisplayContentModeTransitionWithCoordinator:"),longTransition);
    assert(longTransition.handler && longTransition.postflight && vpPanelHoldUsesNativeLifecycle);
    assert(vpPanelHoldAwaitingChange);
    vpPanelHoldFollowOwner(NO);
    assert(vpPanelHoldAwaitingChange);
    longTransition.postflight(nil,nil);
    assert(!vpPanelHoldAwaitingChange);
    vpPanelHoldGeneration++;
    vpPanelHoldAwaitingChange=YES;
    longTransition.postflight(nil,nil);
    assert(vpPanelHoldAwaitingChange);
    dispatch_source_cancel(vpPanelHoldWatch);
    vpPanelHoldWatch=nil;
    vpPanelHold=nil;
    // Awake transitions keep snapshot cloak transparent and avoid deferring the arriving effect;
    // panel-off transitions preserve native cloak opacity and defer behavior.
    FoldCloakView *cloakView = [FoldCloakView new];
    fixtureCloakView = cloakView;
    vpOriginalSnapshotHandleTransition = (IMP)originalSnapshotHandleTransition;
    vpOriginalShouldDeferEffectUntilReveal = (IMP)originalDeferEffect;
    FoldSnapshotTransitionCoordinator *snapshotCoordinator = [FoldSnapshotTransitionCoordinator new];
    id dummyHost = [NSObject new];
    vpSnapshotHandleTransition(dummyHost, sel_registerName("displayContentModeCoordinator:handleDisplayContentModeTransition:"), nil, snapshotCoordinator);
    assert(snapshotCoordinator.preflight != nil);
    vpPanelOnAt = 0; vpScreenBlankChangedAt = 0; vpPrimaryAppliedState = 1;
    snapshotCoordinator.cloakInstaller();
    snapshotCoordinator.preflight(nil);
    assert(cloakView.alpha == 0.0);
    assert(!vpShouldDeferEffectUntilReveal(nil, sel_registerName("_shouldDeferEffectUntilRevealForContext:"), nil));
    vpPrimaryAppliedState = 0;
    snapshotCoordinator.cloakInstaller();
    snapshotCoordinator.preflight(nil);
    assert([cloakView.backgroundColor isEqual:@"black"] && cloakView.alpha == 1.0);
    assert(vpShouldDeferEffectUntilReveal(nil, sel_registerName("_shouldDeferEffectUntilRevealForContext:"), nil));
    // Close swap isolates the departing surface into a veil layer that dissolves
    // across [swap .. didChange]; open swap removes lingering dissolve layers.
    Class layerClass = objc_getClass("CALayer");
    assert(layerClass != Nil);
    id holdLayer = [layerClass new];
    CGRect holdBounds = CGRectMake(0, 0, 1200, 2600);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(holdLayer, sel_registerName("setBounds:"), holdBounds);
    id shownProbe = [@"shown-probe" mutableCopy];
    id spareVeil = [@"spare-veil" mutableCopy];
    vpPanelHoldProbes[0] = (__bridge_retained void *)shownProbe;
    vpPanelHoldVeilSurface = (__bridge_retained void *)spareVeil;
    vpPanelHoldProbeShown = 0;
    vpPanelHold = holdLayer;
    vpPanelHoldAwaitingChange = YES;
    vpPrimaryAppliedState = 1;
    vpCrossfadePanelHoldSwap(NO);
    assert(vpPanelHoldProbes[0] == (__bridge void *)spareVeil);
    assert(vpPanelHoldVeilSurface == (__bridge void *)shownProbe);
    NSArray *sublayers = [holdLayer valueForKey:@"sublayers"];
    assert(sublayers.count == 1);
    id veil = sublayers[0];
    assert([veil valueForKey:@"contents"] == shownProbe);
    assert([[veil valueForKey:@"opacity"] floatValue] == 0.0f);
    assert(CGRectEqualToRect(((CGRect (*)(id, SEL))objc_msgSend)(veil, sel_registerName("frame")), holdBounds));
    id dissolve = ((id (*)(id, SEL, id))objc_msgSend)(veil, sel_registerName("animationForKey:"), @"vpCloseDissolve");
    assert(dissolve && [[dissolve valueForKey:@"keyPath"] isEqual:@"opacity"]);
    assert([[dissolve valueForKey:@"fromValue"] isEqual:@1.0] && [[dissolve valueForKey:@"toValue"] isEqual:@0.0]);
    assert(fabs([[dissolve valueForKey:@"duration"] doubleValue] - 0.24) < 1e-6);
    assert([[dissolve valueForKey:@"removedOnCompletion"] boolValue]);
    vpCrossfadePanelHoldSwap(YES);
    assert([[holdLayer valueForKey:@"sublayers"] count] == 0);
    CFRelease(vpPanelHoldProbes[0]);
    CFRelease(vpPanelHoldVeilSurface);
    vpPanelHoldProbes[0] = NULL;
    vpPanelHoldVeilSurface = NULL;
    vpPanelHoldProbeShown = -1;
    vpPanelHoldAwaitingChange = NO;
    vpPanelHold = nil;
    puts("FoldDisplay panel power: ownership, actual off, wake, native mode, postflight, cloak/defer, close dissolve and obsolete completion passed");
} }

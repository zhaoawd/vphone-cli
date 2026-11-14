#import "FoldDisplayPrivate.h"

static IMP vpOriginalContentModeUnlock, vpOriginalBacklightRequest;
static NSString *(*vpDescribeUnlockSource)(int);
static NSString *(*vpDescribeBacklightSource)(NSInteger);
static BOOL (*vpBacklightStateIsActive)(NSInteger);
static BOOL (*vpAlwaysOnForUnlock)(void), (*vpAlwaysOnForBacklight)(void);
static NSInteger vpInactiveBacklightState;

static BOOL vpContentModeUnlock(id self, SEL selector, int source, NSDictionary *options, id completion) {
    if (vpAlwaysOnForUnlock()
        && [vpDescribeUnlockSource(source) isEqualToString:@"DisplayContentModeTransition"]
        && (!options || [options isKindOfClass:NSDictionary.class])) {
        NSMutableDictionary *preserved = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
        preserved[@"SBUIUnlockOptionsTurnOnScreenFirstKey"] = @NO;
        preserved[@"SBUIUnlockOptionsNoBacklightChangesKey"] = @YES;
        preserved[@"SBUIUnlockOptionsOnlyWakeToActionsKey"] = @YES;
        preserved[@"SBUIUnlockOptionsSuppressingWakeToKey"] = @YES;
        options = preserved;
    }
    return ((BOOL (*)(id, SEL, int, id, id))vpOriginalContentModeUnlock)(self, selector, source, options, completion);
}

static void vpContentModeBacklight(id self, SEL selector, NSInteger state, NSInteger from, NSInteger source, BOOL animated, id completion) {
    // Content-mode activation also requests backlight directly, independently
    // of the unlock options. Preserve native inactive state only for that
    // request while the shared panel is still drawing its always-on screen.
    if (vpAlwaysOnForBacklight() && vpBacklightStateIsActive(state)
        && [vpDescribeBacklightSource(source) isEqualToString:@"display content mode transition"])
        state = vpInactiveBacklightState;
    ((void (*)(id, SEL, NSInteger, NSInteger, NSInteger, BOOL, id))vpOriginalBacklightRequest)(self, selector, state, from, source, animated, completion);
}

BOOL vpInstallAlwaysOnWakePolicyForClass(Class cls, NSString *(*describe)(int), BOOL (*alwaysOn)(void)) {
    Method method = class_getInstanceMethod(cls, sel_registerName("unlockUIFromSource:withOptions:completion:"));
    if (!method || !describe || !alwaysOn || strcmp(method_getTypeEncoding(method), "B36@0:8i16@20@?28")) return NO;
    vpDescribeUnlockSource = describe;
    vpAlwaysOnForUnlock = alwaysOn;
    vpOriginalContentModeUnlock = method_setImplementation(method, (IMP)vpContentModeUnlock);
    return YES;
}

BOOL vpInstallAlwaysOnBacklightPolicyForClass(Class cls, NSString *(*describeSource)(NSInteger), BOOL (*isActive)(NSInteger), NSInteger (*fromString)(NSString *), NSString *(*describeState)(NSInteger), BOOL (*alwaysOn)(void)) {
    Method method = class_getInstanceMethod(cls, sel_registerName("_setBacklightState:fromBacklightState:source:animated:completion:"));
    if (!method || !describeSource || !isActive || !fromString || !describeState || !alwaysOn
        || strcmp(method_getTypeEncoding(method), "v52@0:8q16q24q32B40@?44")) return NO;
    NSInteger inactive = fromString(@"inactive");
    if (![describeState(inactive) isEqualToString:@"inactive"] || isActive(inactive)) return NO;
    vpDescribeBacklightSource = describeSource;
    vpBacklightStateIsActive = isActive;
    vpAlwaysOnForBacklight = alwaysOn;
    vpInactiveBacklightState = inactive;
    vpOriginalBacklightRequest = method_setImplementation(method, (IMP)vpContentModeBacklight);
    return YES;
}

void vpInstallAlwaysOnWakePolicy(void) {
    if (!vpInstallAlwaysOnWakePolicyForClass(objc_getClass("SBLockScreenManager"), dlsym(RTLD_DEFAULT, "NSStringFromUnlockSource"), vpPanelIsAlwaysOn))
        vpFoldDisplayLog(@"always-on: content-mode unlock ABI unavailable");
    if (!vpInstallAlwaysOnBacklightPolicyForClass(objc_getClass("SBBacklightController"),
        dlsym(RTLD_DEFAULT, "SBSBacklightChangeSourceDescription"), dlsym(RTLD_DEFAULT, "SBBacklightStateIsActive"),
        dlsym(RTLD_DEFAULT, "SBBacklightStateFromString"), dlsym(RTLD_DEFAULT, "SBBacklightStateDescription"), vpPanelIsAlwaysOn))
        vpFoldDisplayLog(@"always-on: content-mode backlight ABI unavailable");
}

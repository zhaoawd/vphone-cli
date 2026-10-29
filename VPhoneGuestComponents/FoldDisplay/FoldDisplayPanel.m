// SpringBoard: one physical panel for two displays. The cover and the inner
// display share this guest's only scanout, the primary; open, SpringBoard
// composites the inner display onto it.

#import "FoldDisplayPrivate.h"

static void vpShowInnerDisplay(BOOL shown);
static void vpHoldPanel(void);
static void vpReleasePanelHold(NSString *reason);
static void vpReleasePanelHoldAfter(double seconds, NSString *reason);

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
// Opening moves the primary content to the inner display before SpringBoard
// asks for the inner display's power; until it does, the scanout stays lit
// (turning it off there blanked the panel for the time between the two).
static BOOL vpInnerAskedWhileOwning;

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

static void vpApplyPanelState(id control, long long state, long long *applied, id completion) {
    if (!control || (state == *applied && !completion)) return;
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: apply display %u state %lld (was %lld, inner owns %d)",
        vpStateControlDisplayId(control), state, *applied, vpInnerOwnsPanel()]);
    *applied = state;
    ((void (*)(id, SEL, long long, id))vpOriginalTransitionDisplayState)(control,
        sel_registerName("transitionToDisplayState:withCompletion:"), state, completion);
}

// Which display held the panel at the last look, -1 before the first.
static int vpInnerOwnedPanel = -1;

// The coordinator's primary scene moves with the fold, sometimes well after
// SpringBoard starts the transition; every look at the panel notes the move.
static void vpNoteOwnership(BOOL innerOwns) {
    if (innerOwns == vpInnerOwnedPanel) return;
    BOOL closed = vpInnerOwnedPanel == 1 && !innerOwns;
    vpInnerOwnedPanel = innerOwns;
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: panel owned by the %@", innerOwns ? @"inner display" : @"cover"]);
    // Opening releases the hold with the inner display's first frame.
    if (closed) vpReleasePanelHoldAfter(0.15, @"cover redrawn");
}

static void vpApplyPanelStates(id primaryCompletion, id innerCompletion) {
    BOOL innerOwns = vpInnerOwnsPanel();
    vpNoteOwnership(innerOwns);
    if (!innerOwns) vpInnerAskedWhileOwning = NO;
    long long primary = innerOwns ? (vpInnerAskedWhileOwning ? vpInnerWantedState : 1) : vpPrimaryWantedState;
    vpApplyPanelState(vpPrimaryStateControl, primary ? 1 : 0, &vpPrimaryAppliedState, primaryCompletion);
    long long inner = innerOwns && vpInnerWantedState ? 1 : 0;
    BOOL changed = inner != vpInnerAppliedState;
    vpApplyPanelState(vpInnerStateControl, inner, &vpInnerAppliedState, innerCompletion);
    if (changed && vpInnerStateControl) dispatch_async(dispatch_get_main_queue(), ^{ vpShowInnerDisplay(inner != 0); });
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
    unsigned int displayId = vpStateControlDisplayId(self);
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: display %u wants state %lld", displayId, state]);
    if (displayId == 1) {
        vpAdoptInnerStateControl();
        vpPrimaryStateControl = self;
        vpPrimaryWantedState = state;
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
    if (vpInnerOwnsPanel()) vpInnerAskedWhileOwning = YES;
    vpApplyPanelStates(nil, completion);
}

// A fold moves the primary content to the other panel, which takes the
// scanout over even when no power request comes with it.
static IMP vpOriginalPerformContentModeTransition;

// The panel keeps its last frame across the hand-over (vpHoldPanel): opening,
// until the inner display has drawn something other than black; closing,
// until the cover has had time to draw again, since nothing reports that.
// The primary scene moves 100 ms or more after the transition starts (with
// an app in front, later still), so a transition that hands nothing over
// only ends at the hold's one-second limit.
static void vpFollowContentModeTransition(id self, SEL selector, id transitionCoordinator) {
    vpHoldPanel();
    ((void (*)(id, SEL, id))vpOriginalPerformContentModeTransition)(self, selector, transitionCoordinator);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (vpInnerOwnsPanel() != vpInnerOwnedPanel) vpApplyPanelStates(nil, nil);
    });
}

static void vpInstallContentModeOwnership(void) {
    Method perform = class_getInstanceMethod(objc_getClass("SBDisplayContentModeCoordinator"),
        sel_registerName("performDisplayContentModeTransitionWithCoordinator:"));
    if (!perform || strcmp(method_getTypeEncoding(perform), "v24@0:8@16") != 0) {
        vpFoldDisplayLog(@"inner display: content mode transition ABI unavailable");
        return;
    }
    vpOriginalPerformContentModeTransition = method_setImplementation(perform, (IMP)vpFollowContentModeTransition);
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
    vpInstallContentModeOwnership();
    vpFoldDisplayLog(@"inner display: shared scanout installed");
}

// MARK: - compositing

// The render server's own clone of a display (addClone:options:) shows
// nothing on this guest's paravirtual panel (black with every option), so
// SpringBoard shows the inner display there itself: on every primary frame
// it has the render server draw the inner display into a surface
// (CARenderServerRenderDisplay) and shows that surface in a layer at the top
// of Main's root scene window (UIRootSceneWindow, the window Main's scenes
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
// Three surfaces take turns, so the render server never draws into the one
// the panel shows or the one it showed last. Each frame of the inner display
// reaches the panel one primary frame later.
static id vpInnerPanelRoot, vpInnerPanelImage, vpInnerPanelRefresh;
static void *vpInnerPanelSurfaces[3];
static int vpInnerPanelShown;
static BOOL vpInnerPanelRendering; // main thread only
static BOOL vpInnerPanelAwaitingFirstFrame; // main thread only
static dispatch_queue_t vpInnerPanelQueue;
static void (*vpRenderDisplay)(mach_port_t, CFStringRef, void *, int32_t, int32_t);
// CAFrameRateRange: minimum, maximum, preferred.
typedef struct { float minimum, maximum, preferred; } VPhoneFrameRateRange;

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
    if (!surface || !lock || !unlock || !base || !width || !height || !bytesPerRow) return YES;
    if (lock(surface, 1 /* read-only */, NULL) != 0) return YES;
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

@interface VPhoneInnerPanelRefresh : NSObject
@end

@implementation VPhoneInnerPanelRefresh
- (void)refresh:(id)link {
    if (vpInnerPanelRendering) return;
    vpInnerPanelRendering = YES;
    int next = (vpInnerPanelShown + 1) % 3;
    void *surface = vpInnerPanelSurfaces[next];
    id image = vpInnerPanelImage;
    BOOL checkDrawn = vpInnerPanelAwaitingFirstFrame;
    dispatch_async(vpInnerPanelQueue, ^{
        vpRenderDisplay(0, (__bridge CFStringRef)vpInnerDisplayName, surface, 0, 0);
        BOOL drawn = !checkDrawn || vpSurfaceHasContent(surface);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (image == vpInnerPanelImage) {
                vpInnerPanelShown = next;
                Class transaction = objc_getClass("CATransaction");
                ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("begin"));
                ((void (*)(id, SEL, BOOL))objc_msgSend)(transaction, sel_registerName("setDisableActions:"), YES);
                ((void (*)(id, SEL, id))objc_msgSend)(image, sel_registerName("setContents:"), (__bridge id)surface);
                // The hold goes in the commit that brings the first frame
                // with something on it: an app moving over draws black for
                // up to a second first.
                if (vpInnerPanelAwaitingFirstFrame && drawn) {
                    vpInnerPanelAwaitingFirstFrame = NO;
                    vpReleasePanelHold(@"inner display drawn");
                }
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

static void vpReleaseInnerPanelSurfaces(void) {
    for (int index = 0; index < 3; index++) {
        if (vpInnerPanelSurfaces[index]) CFRelease(vpInnerPanelSurfaces[index]);
        vpInnerPanelSurfaces[index] = NULL;
    }
}

static void *vpCreatePanelSurface(CGSize pixels) {
    static void *(*createSurface)(CFDictionaryRef);
    if (!createSurface)
        createSurface = dlsym(dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW), "IOSurfaceCreate");
    if (!createSurface || pixels.width < 1 || pixels.height < 1) return NULL;
    NSDictionary *properties = @{@"IOSurfaceWidth": @(pixels.width), @"IOSurfaceHeight": @(pixels.height),
        @"IOSurfaceBytesPerElement": @4, @"IOSurfacePixelFormat": @((uint32_t)'BGRA')};
    return createSurface((__bridge CFDictionaryRef)properties);
}

// MARK: - hand-over hold

// A fold hands the panel from one display to the other in steps: SpringBoard
// takes the cover's scenes off Main, then the inner display's frame reaches
// the panel a few frames later (opening), or the compositor leaves before the
// cover has drawn again (closing). In between the panel showed black for up
// to 200 ms, more with an app in front. The hold is the panel's last frame,
// drawn by the render server into a surface of its own and shown above
// everything on Main's root scene window, from the moment SpringBoard starts
// the transition until the other display's frame is there.
static id vpPanelHold;
static void *vpPanelHoldSurface;
static double vpPanelHoldSince;
static unsigned vpPanelHoldGeneration;

static void vpHoldPanel(void) {
    if (vpPanelHold) return;
    @try {
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
        double start = NSDate.date.timeIntervalSince1970;
        vpRenderDisplay(0, (__bridge CFStringRef)name, surface, 0, 0);
        id rootLayer = vpReadObject(rootWindow, "layer");
        id hold = [objc_getClass("CALayer") new];
        ((void (*)(id, SEL, CGRect))objc_msgSend)(hold, sel_registerName("setFrame:"),
            ((CGRect (*)(id, SEL))objc_msgSend)(rootLayer, sel_registerName("bounds")));
        ((void (*)(id, SEL, double))objc_msgSend)(hold, sel_registerName("setZPosition:"), 2.0e9);
        Class transaction = objc_getClass("CATransaction");
        ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("begin"));
        ((void (*)(id, SEL, BOOL))objc_msgSend)(transaction, sel_registerName("setDisableActions:"), YES);
        ((void (*)(id, SEL, id))objc_msgSend)(hold, sel_registerName("setContents:"), (__bridge id)surface);
        ((void (*)(id, SEL, id))objc_msgSend)(rootLayer, sel_registerName("addSublayer:"), hold);
        ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("commit"));
        vpPanelHold = hold;
        vpPanelHoldSurface = surface;
        vpPanelHoldSince = NSDate.date.timeIntervalSince1970;
        unsigned generation = ++vpPanelHoldGeneration;
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: hold on (%@ rendered in %.0f ms, window %p)",
            name, (vpPanelHoldSince - start) * 1000, rootWindow]);
        // Never longer than two seconds, whatever the hand-over does.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation == vpPanelHoldGeneration) vpReleasePanelHold(@"timeout");
        });
    } @catch (NSException *exception) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: hold exception %@", exception.reason]);
    }
}

static void vpReleasePanelHold(NSString *reason) {
    if (!vpPanelHold) return;
    Class transaction = objc_getClass("CATransaction");
    ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("begin"));
    ((void (*)(id, SEL, BOOL))objc_msgSend)(transaction, sel_registerName("setDisableActions:"), YES);
    ((void (*)(id, SEL))objc_msgSend)(vpPanelHold, sel_registerName("removeFromSuperlayer"));
    ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("commit"));
    vpPanelHold = nil;
    vpPanelHoldGeneration++;
    // The render server may still show the old contents for this commit.
    void *surface = vpPanelHoldSurface;
    vpPanelHoldSurface = NULL;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (surface) CFRelease(surface);
    });
    vpFoldDisplayLog([NSString stringWithFormat:@"inner display: hold off (%@) after %.0f ms",
        reason, (NSDate.date.timeIntervalSince1970 - vpPanelHoldSince) * 1000]);
}

static void vpReleasePanelHoldAfter(double seconds, NSString *reason) {
    unsigned generation = vpPanelHoldGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation == vpPanelHoldGeneration) vpReleasePanelHold(reason);
    });
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
        id rootWindow = vpMainRootSceneWindow();
        CGSize pixels = vpInnerDisplayPixels();
        void *(*createSurface)(CFDictionaryRef) =
            dlsym(dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW), "IOSurfaceCreate");
        if (!vpRenderDisplay) vpRenderDisplay = dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        if (!rootWindow || pixels.width < 1 || !createSurface || !vpRenderDisplay) {
            vpFoldDisplayLog([NSString stringWithFormat:@"inner display: show unavailable root=%@ pixels={%.0f, %.0f}",
                rootWindow, pixels.width, pixels.height]);
            return;
        }
        if (!vpInnerPanelSurfaces[0]) {
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
        // The inner display fills the panel, turned a quarter (-90 degrees)
        // when it reads landscape on the portrait panel. The panel is the
        // cover's, a little narrower than the inner display (1398x2034
        // against 2007x2853), so the fill is about 2% tighter across than
        // along; it leaves no bars, and the digitizer, which spans the panel,
        // maps onto the whole inner display as it is.
        id rootLayer = vpReadObject(rootWindow, "layer");
        CGRect panel = ((CGRect (*)(id, SEL))objc_msgSend)(rootLayer, sel_registerName("bounds"));
        CGFloat pointScale = ((double (*)(id, SEL))objc_msgSend)(vpReadObject(rootWindow, "screen"), sel_registerName("scale"));
        CGSize inner = CGSizeMake(pixels.width / pointScale, pixels.height / pointScale);
        BOOL turned = inner.width > inner.height;
        CGSize upright = turned ? CGSizeMake(inner.height, inner.width) : inner;
        CGAffineTransform transform = CGAffineTransformConcat(
            turned ? CGAffineTransformMakeRotation(-M_PI_2) : CGAffineTransformIdentity,
            CGAffineTransformMakeScale(panel.size.width / upright.width, panel.size.height / upright.height));
        id root = [objc_getClass("CALayer") new];
        ((void (*)(id, SEL, CGRect))objc_msgSend)(root, sel_registerName("setFrame:"), panel);
        ((void (*)(id, SEL, CGColorRef))objc_msgSend)(root, sel_registerName("setBackgroundColor:"),
            ((CGColorRef (*)(id, SEL))objc_msgSend)(vpReadObject(objc_getClass("UIColor"), "blackColor"), sel_registerName("CGColor")));
        ((void (*)(id, SEL, double))objc_msgSend)(root, sel_registerName("setZPosition:"), 1.0e9);
        id image = [objc_getClass("CALayer") new];
        ((void (*)(id, SEL, CGRect))objc_msgSend)(image, sel_registerName("setBounds:"), (CGRect){CGPointZero, inner});
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(image, sel_registerName("setPosition:"), CGPointMake(CGRectGetMidX(panel), CGRectGetMidY(panel)));
        ((void (*)(id, SEL, CGAffineTransform))objc_msgSend)(image, sel_registerName("setAffineTransform:"), transform);
        ((void (*)(id, SEL, id))objc_msgSend)(root, sel_registerName("addSublayer:"), image);
        ((void (*)(id, SEL, id))objc_msgSend)(rootLayer, sel_registerName("addSublayer:"), root);
        vpInnerPanelRoot = root;
        vpInnerPanelImage = image;
        vpInnerPanelAwaitingFirstFrame = YES;
        vpInnerPanelRefresh = ((id (*)(id, SEL, id, SEL))objc_msgSend)(objc_getClass("CADisplayLink"),
            sel_registerName("displayLinkWithTarget:selector:"), [VPhoneInnerPanelRefresh new], @selector(refresh:));
        // The panel shows the inner display at the panel's top rate, asked for
        // rather than left to the system's choice for a link with no range.
        NSInteger fps = ((NSInteger (*)(id, SEL))objc_msgSend)(vpReadObject(rootWindow, "screen"), sel_registerName("maximumFramesPerSecond"));
        SEL setRange = sel_registerName("setPreferredFrameRateRange:");
        if (fps > 60 && [vpInnerPanelRefresh respondsToSelector:setRange])
            ((void (*)(id, SEL, VPhoneFrameRateRange))objc_msgSend)(vpInnerPanelRefresh, setRange, (VPhoneFrameRateRange){fps, fps, fps});
        ((void (*)(id, SEL, id, id))objc_msgSend)(vpInnerPanelRefresh, sel_registerName("addToRunLoop:forMode:"),
            NSRunLoop.mainRunLoop, NSRunLoopCommonModes);
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: shown=1 panel={%.0f, %.0f} inner={%.0f, %.0f} turned=%d scale={%.3f, %.3f} fps=%ld window %p hidden=%d",
            panel.size.width, panel.size.height, inner.width, inner.height, turned,
            panel.size.width / upright.width, panel.size.height / upright.height, (long)fps, rootWindow,
            ((BOOL (*)(id, SEL))objc_msgSend)(rootWindow, sel_registerName("isHidden"))]);
    } @catch (NSException *exception) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner display: show exception %@", exception.reason]);
    }
}

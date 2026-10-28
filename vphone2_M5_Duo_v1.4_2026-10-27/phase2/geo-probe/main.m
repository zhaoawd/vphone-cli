// GeoProbe: records the geometry an app sees, to compare the VM's single-display
// inner-panel mode with the iPhone Duo simulator. Two builds from this source:
//
//   GeoProbe (mode B)  standard UINavigationController with left/right bar
//                      buttons and a toolbar: do system bars clear the status bar?
//   GeoBare  (mode A, -DGEO_BARE)  no container; a non-interactive overlay marks
//                      the safe area, the status bar rect and reserved regions:
//                      what does the system give the app?
//
// Each sample (after the first stable appearance, trait or size changes and
// returns to the foreground, only when the content changed) is written to
// Documents/geometry.json (latest) and Documents/geometry-<n>.json, and logged
// as "[geo-probe] {...}". All rects are also given in the root view's space.
#import <UIKit/UIKit.h>
#include <sys/sysctl.h>

#ifdef GEO_BARE
static NSString *const kMode = @"A-bare";
#else
static NSString *const kMode = @"B-navigation";
#endif

static NSDictionary *rect(CGRect r) {
  return @{@"x": @(r.origin.x), @"y": @(r.origin.y), @"w": @(r.size.width), @"h": @(r.size.height)};
}
static NSDictionary *insets(UIEdgeInsets i) {
  return @{@"top": @(i.top), @"left": @(i.left), @"bottom": @(i.bottom), @"right": @(i.right)};
}
static NSDictionary *dirInsets(NSDirectionalEdgeInsets i) {
  return @{@"top": @(i.top), @"leading": @(i.leading), @"bottom": @(i.bottom), @"trailing": @(i.trailing)};
}
static NSString *sizeClass(UIUserInterfaceSizeClass c) {
  return c == UIUserInterfaceSizeClassCompact ? @"compact" : c == UIUserInterfaceSizeClassRegular ? @"regular" : @"unspecified";
}
static NSDictionary *screen(UIScreen *s) {
  return @{@"bounds": rect(s.bounds), @"nativeBounds": rect(s.nativeBounds), @"scale": @(s.scale), @"nativeScale": @(s.nativeScale)};
}
static NSString *sysctlString(const char *name) {
  char buf[256] = {0};
  size_t len = sizeof buf - 1;
  return sysctlbyname(name, buf, &len, NULL, 0) == 0 ? @(buf) : @"?";
}

@interface GeoViewController : UIViewController
@property(nonatomic, strong) UIView *safeBox;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) UIView *overlay;
@property(nonatomic, copy) NSString *lastSample;
@property(nonatomic) NSUInteger sampleCount;
@end

@implementation GeoViewController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"GeoProbe";
  self.view.backgroundColor = UIColor.systemYellowColor;
  self.safeBox = [UIView new];
  self.safeBox.translatesAutoresizingMaskIntoConstraints = NO;
  self.safeBox.backgroundColor = UIColor.systemBackgroundColor;
  self.safeBox.layer.borderColor = UIColor.systemRedColor.CGColor;
  self.safeBox.layer.borderWidth = 4;
  [self.view addSubview:self.safeBox];
  UILayoutGuide *g = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [self.safeBox.topAnchor constraintEqualToAnchor:g.topAnchor],
    [self.safeBox.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
    [self.safeBox.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
    [self.safeBox.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
  ]];
  self.label = [UILabel new];
  self.label.numberOfLines = 0;
  self.label.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
  self.label.translatesAutoresizingMaskIntoConstraints = NO;
  [self.safeBox addSubview:self.label];
  [NSLayoutConstraint activateConstraints:@[
    [self.label.topAnchor constraintEqualToAnchor:self.safeBox.topAnchor constant:8],
    [self.label.leadingAnchor constraintEqualToAnchor:self.safeBox.leadingAnchor constant:8],
    [self.label.trailingAnchor constraintEqualToAnchor:self.safeBox.trailingAnchor constant:-8],
  ]];
#ifndef GEO_BARE
  self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"LeftEdge" style:UIBarButtonItemStylePlain target:nil action:nil];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"RightEdge" style:UIBarButtonItemStylePlain target:nil action:nil];
  self.toolbarItems = @[
    [[UIBarButtonItem alloc] initWithTitle:@"ToolLeft" style:UIBarButtonItemStylePlain target:nil action:nil],
    [UIBarButtonItem flexibleSpaceItem],
    [[UIBarButtonItem alloc] initWithTitle:@"ToolRight" style:UIBarButtonItemStylePlain target:nil action:nil],
  ];
#endif
  // Drawn above everything, never hit-tested and never constrained to anything,
  // so it cannot change the layout it reports.
  self.overlay = [UIView new];
  self.overlay.userInteractionEnabled = NO;
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(foregrounded)
                                             name:UISceneWillEnterForegroundNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  [self.view.window addSubview:self.overlay];
  [self sampleAfterDelay:@"appeared"];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
  [super traitCollectionDidChange:previous];
  [self sampleAfterDelay:@"traits"];
}
- (void)viewSafeAreaInsetsDidChange {
  [super viewSafeAreaInsetsDidChange];
  [self sampleAfterDelay:@"safe-area"];
}
// A rotation on a regular/regular display changes no trait, so sample on size changes too.
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
  [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
  [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
    [self sampleAfterDelay:@"size"];
  }];
}
- (void)foregrounded {
  [self sampleAfterDelay:@"foreground"];
}

- (void)sampleAfterDelay:(NSString *)reason {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self sample:reason]; });
}

- (NSArray *)regionsOfKind:(UIViewReservedRegionKind *)kind name:(NSString *)name {
  NSMutableArray *out = [NSMutableArray array];
  for (UIViewReservedRegion *r in [self.view reservedRegionsOfKind:kind options:UIViewReservedRegionQueryOptionsIncludeInactive]) {
    [out addObject:@{@"kind": name, @"frame": rect(r.frame), @"margins": insets(r.margins), @"active": @(r.isActive)}];
  }
  return out;
}

- (void)drawOverlayStatusBar:(CGRect)statusBar regions:(NSArray *)regions {
  UIWindow *window = self.view.window;
  self.overlay.frame = window.bounds;
  for (UIView *v in self.overlay.subviews.copy) [v removeFromSuperview];
  void (^box)(CGRect, UIColor *, CGFloat) = ^(CGRect r, UIColor *c, CGFloat fill) {
    UIView *v = [[UIView alloc] initWithFrame:[self.view convertRect:r toView:window]];
    v.layer.borderColor = c.CGColor;
    v.layer.borderWidth = 3;
    v.backgroundColor = [c colorWithAlphaComponent:fill];
    [self.overlay addSubview:v];
  };
  for (NSDictionary *r in regions) {
    NSDictionary *f = r[@"frame"];
    box(CGRectMake([f[@"x"] doubleValue], [f[@"y"] doubleValue], [f[@"w"] doubleValue], [f[@"h"] doubleValue]),
        [r[@"active"] boolValue] ? UIColor.systemGreenColor : UIColor.systemGrayColor, 0.25);
  }
  if (!CGRectIsEmpty(statusBar)) box(statusBar, UIColor.systemBlueColor, 0.35);
  [window bringSubviewToFront:self.overlay];
}

// Status bar views that live in this app's own windows (read only): class,
// frame in the root view's space, and the layout provider class when the view
// exposes one. An empty list means the app draws no status bar of its own.
- (NSArray *)statusBarViewsInScene:(UIWindowScene *)scene {
  NSMutableArray *found = [NSMutableArray array];
  __block void (^walk)(UIView *, NSUInteger);
  __block __weak void (^weakWalk)(UIView *, NSUInteger);
  walk = ^(UIView *v, NSUInteger depth) {
    NSString *name = NSStringFromClass(v.class);
    if ([name rangeOfString:@"StatusBar" options:NSCaseInsensitiveSearch].location != NSNotFound) {
      NSMutableDictionary *e = [@{@"class": name, @"depth": @(depth), @"hidden": @(v.isHidden), @"alpha": @(v.alpha),
                                  @"window": NSStringFromClass(v.window.class) ?: @"?",
                                  @"frameInRootView": rect([v convertRect:v.bounds toView:self.view])} mutableCopy];
      SEL provider = NSSelectorFromString(@"visualProvider");
      if ([v respondsToSelector:provider]) {
        id p = [v valueForKey:@"visualProvider"];
        e[@"visualProvider"] = p ? NSStringFromClass([p class]) : @"nil";
      }
      [found addObject:e];
    }
    for (UIView *sub in v.subviews) weakWalk(sub, depth + 1);
  };
  weakWalk = walk;
  for (UIWindow *w in scene.windows) walk(w, 0);
  return found;
}

- (void)sample:(NSString *)reason {
  UIWindow *window = self.view.window;
  if (!window) return;
  UIWindowScene *scene = window.windowScene;
  UITraitCollection *t = self.traitCollection;
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  d[@"device"] = @{@"model": UIDevice.currentDevice.model, @"system": UIDevice.currentDevice.systemVersion,
                   @"systemBuild": sysctlString("kern.osversion"), @"hwModel": sysctlString("hw.machine"),
                   @"idiom": @(UIDevice.currentDevice.userInterfaceIdiom)};
  d[@"build"] = @{@"mode": kMode, @"sdkMaxAllowed": @(__IPHONE_OS_VERSION_MAX_ALLOWED),
                  @"bundleVersion": NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"?"};
  d[@"mainScreen"] = screen(UIScreen.mainScreen);

  CGRect statusBarInView = CGRectZero;
  if (scene) {
    d[@"sceneScreen"] = screen(scene.screen);
    d[@"sceneCoordinateSpace"] = rect(scene.coordinateSpace.bounds);
    d[@"sceneActivation"] = @(scene.activationState);
    d[@"effectiveGeometry"] = @{@"bounds": rect(scene.effectiveGeometry.coordinateSpace.bounds),
                                @"interfaceOrientation": @(scene.effectiveGeometry.interfaceOrientation),
                                @"readPath": @"effectiveGeometry.coordinateSpace"};
    UIStatusBarManager *sbm = scene.statusBarManager;
    if (sbm) {
      CGRect raw = sbm.statusBarFrame;  // scene coordinates; zero when hidden
      statusBarInView = [self.view convertRect:raw fromCoordinateSpace:scene.coordinateSpace];
      d[@"statusBar"] = @{@"manager": @YES, @"hidden": @(sbm.statusBarHidden), @"frameInScene": rect(raw),
                          @"frameInRootView": rect(statusBarInView), @"isZero": @(CGRectEqualToRect(raw, CGRectZero))};
    } else {
      d[@"statusBar"] = @{@"manager": @NO};
    }
    d[@"statusBarViews"] = [self statusBarViewsInScene:scene];
  }
  d[@"window"] = @{@"frame": rect(window.frame), @"bounds": rect(window.bounds), @"safeArea": insets(window.safeAreaInsets)};
  d[@"rootView"] = @{@"bounds": rect(self.view.bounds), @"safeArea": insets(self.view.safeAreaInsets),
                     @"safeLayoutFrame": rect(self.view.safeAreaLayoutGuide.layoutFrame),
                     @"directionalLayoutMargins": dirInsets(self.view.directionalLayoutMargins)};
  d[@"controller"] = @{@"additionalSafeArea": insets(self.additionalSafeAreaInsets)};
  NSArray *regions = [[self regionsOfKind:UIViewReservedRegionKind.occlusionRegionKind name:@"occlusion"]
                      arrayByAddingObjectsFromArray:[self regionsOfKind:UIViewReservedRegionKind.divisionRegionKind name:@"division"]];
  d[@"reservedRegions"] = regions;
  if (self.navigationController) {
    UINavigationBar *bar = self.navigationController.navigationBar;
    UIToolbar *tool = self.navigationController.toolbar;
    d[@"navigationBar"] = @{@"frameInRootView": rect([bar convertRect:bar.bounds toView:self.view]),
                            @"layoutMargins": insets(bar.layoutMargins)};
    d[@"toolbar"] = @{@"hidden": @(self.navigationController.toolbarHidden),
                      @"frameInRootView": rect([tool convertRect:tool.bounds toView:self.view])};
  }
  d[@"traits"] = @{@"horizontal": sizeClass(t.horizontalSizeClass), @"vertical": sizeClass(t.verticalSizeClass),
                   @"displayScale": @(t.displayScale), @"idiom": @(t.userInterfaceIdiom),
                   @"contentSize": t.preferredContentSizeCategory, @"layoutDirection": @(t.layoutDirection)};

  NSData *content = [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingSortedKeys error:nil];
  NSString *text = [[NSString alloc] initWithData:content encoding:NSUTF8StringEncoding];
  [self drawOverlayStatusBar:statusBarInView regions:regions];
  if ([text isEqualToString:self.lastSample]) return;  // only record changes
  self.lastSample = text;
  self.sampleCount += 1;

  NSMutableDictionary *record = [d mutableCopy];
  record[@"sample"] = @{@"n": @(self.sampleCount), @"reason": reason,
                        @"time": [NSISO8601DateFormatter stringFromDate:NSDate.date timeZone:NSTimeZone.localTimeZone
                                                          formatOptions:NSISO8601DateFormatWithInternetDateTime]};
  NSData *json = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
  NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
  [json writeToURL:[docs URLByAppendingPathComponent:@"geometry.json"] atomically:YES];
  [json writeToURL:[docs URLByAppendingPathComponent:[NSString stringWithFormat:@"geometry-%lu.json", (unsigned long)self.sampleCount]] atomically:YES];
  NSLog(@"[geo-probe] %@", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
  NSData *pretty = [NSJSONSerialization dataWithJSONObject:@{@"mode": kMode, @"sample": @(self.sampleCount), @"statusBar": d[@"statusBar"] ?: @{},
                                                              @"rootSafeArea": d[@"rootView"][@"safeArea"], @"reservedRegions": regions}
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
  self.label.text = [[NSString alloc] initWithData:pretty encoding:NSUTF8StringEncoding];
}
@end

@interface GeoSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation GeoSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
#ifdef GEO_BARE
  self.window.rootViewController = [GeoViewController new];
#else
  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[GeoViewController new]];
  nav.toolbarHidden = NO;
  self.window.rootViewController = nav;
#endif
  [self.window makeKeyAndVisible];
}
@end

@interface GeoAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation GeoAppDelegate
@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass(GeoAppDelegate.class));
  }
}

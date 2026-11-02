// Records actual UIControl actions independently of the ui.tap_element reply.
#import <UIKit/UIKit.h>
#import <unistd.h>

@interface TapProbeController : UIViewController
@property NSMutableArray<UIButton *> *buttons;
@property NSMutableDictionary<NSString *, NSNumber *> *counts;
@property NSString *lastIdentifier;
@property NSUInteger total;
- (void)record;
@end
@implementation TapProbeController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.buttons = [NSMutableArray array];
    self.counts = [NSMutableDictionary dictionary];
    self.lastIdentifier = @"";
    for (int i = 0; i < 9; i++) {
        NSString *identifier = [NSString stringWithFormat:@"tap-%d", i];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.accessibilityIdentifier = identifier;
        [button setTitle:identifier forState:UIControlStateNormal];
        [button addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:button];
        [self.buttons addObject:button];
        self.counts[identifier] = @0;
    }
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect safe = self.view.safeAreaLayoutGuide.layoutFrame;
    for (int i = 0; i < 9; i++) {
        CGPoint centre = CGPointMake(safe.origin.x + safe.size.width * (0.2 + 0.3 * (i % 3)),
                                    safe.origin.y + safe.size.height * (0.2 + 0.3 * (i / 3)));
        self.buttons[i].frame = CGRectMake(centre.x - 36, centre.y - 22, 72, 44);
    }
    [self record];
}
- (void)tapped:(UIButton *)sender {
    self.lastIdentifier = sender.accessibilityIdentifier;
    self.counts[self.lastIdentifier] = @([self.counts[self.lastIdentifier] unsignedIntegerValue] + 1);
    self.total++;
    [self record];
}
- (void)record {
    UIWindowScene *scene = self.view.window.windowScene;
    if (!scene) return;
    UIWindowSceneGeometry *geometry = scene.effectiveGeometry;
    UIScreen *screen = scene.screen;
    NSDictionary *report = @{@"pid": @(getpid()), @"total": @(self.total),
        @"last_identifier": self.lastIdentifier, @"counts": self.counts,
        @"orientation": @(geometry.interfaceOrientation),
        @"scene": @[@(geometry.coordinateSpace.bounds.size.width), @(geometry.coordinateSpace.bounds.size.height)],
        @"view": @[@(self.view.bounds.size.width), @(self.view.bounds.size.height)],
        @"screen": @{@"scale": @(screen.scale), @"native_scale": @(screen.nativeScale),
                     @"bounds": @[@(screen.bounds.size.width), @(screen.bounds.size.height)],
                     @"fixed": @[@(screen.fixedCoordinateSpace.bounds.size.width), @(screen.fixedCoordinateSpace.bounds.size.height)],
                     @"native": @[@(screen.nativeBounds.size.width), @(screen.nativeBounds.size.height)]}};
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [data writeToURL:[documents URLByAppendingPathComponent:@"tap-probe.json"] atomically:YES];
}
@end
@interface TapProbeWindow : UIWindow
@end
@implementation TapProbeWindow
- (void)sendEvent:(UIEvent *)event {
    NSMutableArray *touches = [NSMutableArray array];
    for (UITouch *touch in event.allTouches) {
        CGPoint point = [touch locationInView:self];
        [touches addObject:@{@"phase": @(touch.phase), @"x": @(point.x), @"y": @(point.y),
                            @"identifier": touch.view.accessibilityIdentifier ?: @""}];
    }
    if (touches.count) {
        NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        [[NSJSONSerialization dataWithJSONObject:touches options:0 error:NULL]
            writeToURL:[documents URLByAppendingPathComponent:@"tap-touch.json"] atomically:YES];
    }
    [super sendEvent:event];
}
@end
@interface TapProbeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation TapProbeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[TapProbeWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [TapProbeController new];
    [self.window makeKeyAndVisible];
}
- (void)windowScene:(UIWindowScene *)scene didUpdateEffectiveGeometry:(UIWindowSceneGeometry *)previousGeometry {
    [(TapProbeController *)self.window.rootViewController record];
}
@end
@interface TapProbeDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation TapProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options { return YES; }
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(TapProbeDelegate.class)); }
}

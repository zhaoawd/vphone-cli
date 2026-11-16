// Independent UIKit-to-fixed-screen markers for native capture pixel validation.
#import <UIKit/UIKit.h>
#include <unistd.h>

static NSArray<NSString *> *names(void) { return @[@"red", @"green", @"blue", @"yellow"]; }
static CGPoint centre(CGSize size, NSUInteger index) {
    return CGPointMake(size.width * ((index % 2) ? 0.8 : 0.2), size.height * ((index / 2) ? 0.8 : 0.2));
}
@interface DisplayProbeView : UIView
@property(nonatomic) NSUInteger tick;
@end
@implementation DisplayProbeView
- (void)drawRect:(CGRect)rect {
    [[UIColor colorWithWhite:0.08 alpha:1] setFill]; UIRectFill(self.bounds);
    NSArray<UIColor *> *colors = @[UIColor.redColor, UIColor.greenColor, UIColor.blueColor, UIColor.yellowColor];
    for (NSUInteger i = 0; i < 4; i++) {
        CGPoint point = centre(self.bounds.size, i); [colors[i] setFill];
        UIRectFill(CGRectMake(point.x - 25, point.y - 25, 50, 50));
    }
    NSString *counter = [NSString stringWithFormat:@"%lu", (unsigned long)self.tick];
    [counter drawAtPoint:CGPointMake(self.bounds.size.width * 0.4, self.bounds.size.height * 0.45)
         withAttributes:@{NSFontAttributeName:[UIFont monospacedSystemFontOfSize:36 weight:UIFontWeightBold],
                          NSForegroundColorAttributeName:UIColor.whiteColor}];
}
@end
@interface DisplayProbeController : UIViewController
@property(nonatomic,strong) CADisplayLink *clock;
@property(nonatomic) CFTimeInterval lastSample;
@end
@implementation DisplayProbeController
- (void)loadView { self.view = [DisplayProbeView new]; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.clock) {
        self.clock = [CADisplayLink displayLinkWithTarget:self selector:@selector(sample:)];
        [self.clock addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}
- (void)sample:(CADisplayLink *)clock {
    if (clock.timestamp - self.lastSample < 0.2) return;
    self.lastSample = clock.timestamp;
    DisplayProbeView *view = (DisplayProbeView *)self.view;
    view.tick++; [view setNeedsDisplay];
    UIWindow *window = view.window; UIWindowScene *scene = window.windowScene;
    if (!scene) return;
    NSMutableArray *markers = [NSMutableArray array];
    for (NSUInteger i = 0; i < 4; i++) {
        CGPoint point = [view convertPoint:centre(view.bounds.size, i) toView:window];
        CGPoint fixed = [window convertPoint:point toCoordinateSpace:scene.screen.fixedCoordinateSpace];
        [markers addObject:@{@"color":names()[i], @"window_point":@[@(point.x),@(point.y)],
                             @"fixed_point":@[@(fixed.x),@(fixed.y)]}];
    }
    CGRect fixed = scene.screen.fixedCoordinateSpace.bounds;
    NSDictionary *report = @{@"pid":@(getpid()), @"tick":@(view.tick), @"uptime":@(clock.timestamp),
        @"orientation":@(scene.effectiveGeometry.interfaceOrientation),
        @"window":@[@(window.bounds.size.width),@(window.bounds.size.height)],
        @"fixed":@[@(fixed.size.width),@(fixed.size.height)], @"markers":markers};
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil]
        writeToURL:[documents URLByAppendingPathComponent:@"display-probe.json"] atomically:YES];
}
@end
@interface DisplayProbeScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation DisplayProbeScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [DisplayProbeController new]; [self.window makeKeyAndVisible];
}
@end
@interface DisplayProbeApp : UIResponder <UIApplicationDelegate>
@end
@implementation DisplayProbeApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options { return YES; }
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(DisplayProbeApp.class)); }
}

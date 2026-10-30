// KBProbe: one text field on a coloured view, for the fold-with-keyboard case.
// Every layout pass records the window, scene and screen sizes and the first
// responder state to Documents/kbprobe.json (last state) and kbprobe.log
// (history), and shows them in a label, so the iPhone Duo simulator and the
// VM can be compared after a fold closes with the field focused.

#import <UIKit/UIKit.h>

@interface KBView : UIView
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UILabel *info;
@end

static NSString *KBDocument(NSString *name) {
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [docs URLByAppendingPathComponent:name].path;
}

@implementation KBView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithRed:0.10 green:0.45 blue:0.85 alpha:1];
        _field = [UITextField new];
        _field.borderStyle = UITextBorderStyleRoundedRect;
        _field.placeholder = @"type here";
        _field.accessibilityIdentifier = @"kb-field";
        _field.autocorrectionType = UITextAutocorrectionTypeNo;
        [self addSubview:_field];
        _info = [UILabel new];
        _info.numberOfLines = 0;
        _info.textColor = UIColor.whiteColor;
        _info.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
        _info.accessibilityIdentifier = @"kb-info";
        [self addSubview:_info];
        UIView *corner = [UIView new];
        corner.backgroundColor = UIColor.systemOrangeColor;
        corner.tag = 7;
        corner.accessibilityIdentifier = @"kb-bottom-marker";
        corner.isAccessibilityElement = YES;
        corner.accessibilityLabel = @"bottom marker";
        [self addSubview:corner];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    UIEdgeInsets s = self.safeAreaInsets;
    self.field.frame = CGRectMake(s.left + 20, s.top + 20, b.size.width - s.left - s.right - 40, 44);
    self.info.frame = CGRectMake(s.left + 20, s.top + 80, b.size.width - s.left - s.right - 40, 260);
    // A marker in the bottom 60 pt shows whether the lower part is drawn.
    [self viewWithTag:7].frame = CGRectMake(0, b.size.height - 60, b.size.width, 60);
    [self record:@"layout"];
}

- (void)record:(NSString *)event {
    UIWindowScene *scene = self.window.windowScene;
    CGRect w = self.window.bounds, sc = scene.coordinateSpace.bounds, scr = scene.screen.bounds;
    NSDictionary *state = @{
        @"event": event,
        @"time": @(NSDate.date.timeIntervalSince1970),
        @"view": @[@(self.bounds.size.width), @(self.bounds.size.height)],
        @"window": @[@(w.size.width), @(w.size.height)],
        @"window_hidden": @(self.window.hidden),
        @"scene": @[@(sc.size.width), @(sc.size.height)],
        @"screen": @[@(scr.size.width), @(scr.size.height)],
        @"main_screen": @[@(UIScreen.mainScreen.bounds.size.width), @(UIScreen.mainScreen.bounds.size.height)],
        @"orientation": @(scene.effectiveGeometry.interfaceOrientation),
        @"first_responder": @(self.field.isFirstResponder),
        @"text": self.field.text ?: @"",
    };
    self.info.text = [NSString stringWithFormat:@"view %.0fx%.0f\nwindow %.0fx%.0f\nscene %.0fx%.0f\nscreen %.0fx%.0f\nmain %.0fx%.0f\nfocused %d",
        self.bounds.size.width, self.bounds.size.height, w.size.width, w.size.height, sc.size.width, sc.size.height,
        scr.size.width, scr.size.height, UIScreen.mainScreen.bounds.size.width, UIScreen.mainScreen.bounds.size.height,
        self.field.isFirstResponder];
    NSData *json = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    [json writeToFile:KBDocument(@"kbprobe.json") atomically:YES];
    NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:KBDocument(@"kbprobe.log")];
    if (!log) {
        [NSData.data writeToFile:KBDocument(@"kbprobe.log") atomically:YES];
        log = [NSFileHandle fileHandleForWritingAtPath:KBDocument(@"kbprobe.log")];
    }
    [log seekToEndOfFile];
    [log writeData:json];
    [log writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [log closeFile];
}
@end

@interface KBController : UIViewController
@end

@implementation KBController
- (void)loadView { self.view = [KBView new]; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

@interface KBSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation KBSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [KBController new];
    [self.window makeKeyAndVisible];
}
- (void)windowScene:(UIWindowScene *)scene didUpdateEffectiveGeometry:(UIWindowSceneGeometry *)previous {
    [(KBView *)self.window.rootViewController.view record:@"geometry"];
}
@end

@interface KBAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation KBAppDelegate
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)session
                                   options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    configuration.delegateClass = KBSceneDelegate.class;
    return configuration;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(KBAppDelegate.class));
    }
}

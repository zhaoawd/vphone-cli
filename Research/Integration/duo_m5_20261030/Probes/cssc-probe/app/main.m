// Minimal native Probe App: runs the CSSC probe at launch, shows the JSON and writes Documents/cssc-probe.json.
#import <UIKit/UIKit.h>

int cssc_probe_run(char *out, unsigned long size);

@interface ProbeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ProbeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
  char out[1024];
  int ok = cssc_probe_run(out, sizeof out);
  NSString *json = [NSString stringWithUTF8String:out];
  NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
  [json writeToURL:[docs URLByAppendingPathComponent:@"cssc-probe.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
  NSLog(@"[cssc-probe] %@", json);

  UIViewController *root = [UIViewController new];
  root.view.backgroundColor = ok ? UIColor.systemGreenColor : UIColor.systemRedColor;
  UILabel *label = [UILabel new];
  label.numberOfLines = 0;
  label.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
  label.text = [NSString stringWithFormat:@"Probe %@\n\n%@", ok ? @"PASS" : @"FAIL", json];
  label.frame = CGRectInset(UIScreen.mainScreen.bounds, 16, 80);
  [root.view addSubview:label];

  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
  self.window.rootViewController = root;
  [self.window makeKeyAndVisible];
}
@end

@interface ProbeAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation ProbeAppDelegate
@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeAppDelegate.class));
  }
}

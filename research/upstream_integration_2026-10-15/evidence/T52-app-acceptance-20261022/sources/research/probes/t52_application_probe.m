// Isolated guest acceptance app. Uses public consumer APIs and never reads the
// simulation control file. Building this app does not install or launch it.
#import <AVFoundation/AVFoundation.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>

@interface T52Probe : UIResponder <UIApplicationDelegate, CLLocationManagerDelegate, AVCaptureMetadataOutputObjectsDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) CLLocationManager *location;
@property(nonatomic, strong) AVCaptureSession *capture;
@property(nonatomic, strong) AVCaptureMetadataOutput *metadata;
@property(nonatomic, strong) NSTimer *deadline;
@property(nonatomic, strong) NSMutableDictionary *record;
@property(nonatomic, strong) NSMutableArray *events;
@end

@implementation T52Probe
- (void)save:(NSString *)type fields:(NSDictionary *)fields {
    if (!self.record) return;
    if (self.events.count < 128) {
        NSMutableDictionary *event = [fields mutableCopy];
        event[@"type"] = type;
        event[@"time"] = @([NSDate.date timeIntervalSince1970]);
        [self.events addObject:event];
    }
    self.record[@"events"] = self.events;
    self.record[@"authorization"] = @(self.location.authorizationStatus);
    self.record[@"updatedAt"] = @([NSDate.date timeIntervalSince1970]);
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.record options:NSJSONWritingPrettyPrinted error:nil];
    NSString *directory = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [directory stringByAppendingPathComponent:@"t52-application.json"];
    NSError *error = nil;
    BOOL written = [data writeToFile:path options:NSDataWritingAtomic error:&error];
    self.label.text = [NSString stringWithFormat:@"T52 consumer probe\n%@\n%@\nevents: %lu\n%@",
        self.record[@"runID"], type, (unsigned long)self.events.count, written ? path : error.description];
}

- (void)stop {
    [self.deadline invalidate];
    self.deadline = nil;
    [self.location stopUpdatingLocation];
    self.location.delegate = nil;
    self.location = nil;
    self.metadata = nil;
    [self.capture stopRunning];
    self.capture = nil;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.blackColor;
    self.label = [[UILabel alloc] initWithFrame:CGRectInset(self.window.bounds, 20, 60)];
    self.label.numberOfLines = 0;
    self.label.textColor = UIColor.whiteColor;
    self.label.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    self.label.text = @"T52 consumer probe: waiting for a named run";
    [controller.view addSubview:self.label];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    return YES;
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary *)options {
    (void)application; (void)options;
    if (![url.scheme isEqualToString:@"t52acceptance"]) return NO;
    if ([url.host isEqualToString:@"stop"]) {
        [self stop];
        [self save:@"stopped" fields:@{}];
        return YES;
    }
    if (![@[@"location", @"camera"] containsObject:url.host]) return NO;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *run = nil;
    for (NSURLQueryItem *item in components.queryItems) if ([item.name isEqualToString:@"run"]) run = item.value;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"];
    if (!run.length || run.length > 64 || [run rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;
    [self stop];
    self.events = [NSMutableArray new];
    self.record = [@{@"schemaVersion": @1, @"runID": run, @"mode": url.host,
                     @"pid": @(getpid()), @"bundleID": NSBundle.mainBundle.bundleIdentifier,
                     @"startedAt": @([NSDate.date timeIntervalSince1970])} mutableCopy];
    [self save:@"started" fields:@{}];
    __weak T52Probe *weakSelf = self;
    self.deadline = [NSTimer scheduledTimerWithTimeInterval:60 repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        T52Probe *probe = weakSelf;
        [probe stop];
        [probe save:@"deadline" fields:@{}];
    }];
    if ([url.host isEqualToString:@"location"]) {
        self.location = [CLLocationManager new];
        self.location.delegate = self;
        [self.location requestWhenInUseAuthorization];
        [self.location startUpdatingLocation];
    } else {
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        [self save:@"camera_device" fields:@{@"uniqueID": device.uniqueID ?: @""}];
        NSError *error = nil;
        AVCaptureDeviceInput *input = device ? [AVCaptureDeviceInput deviceInputWithDevice:device error:&error] : nil;
        AVCaptureSession *session = [AVCaptureSession new];
        AVCaptureMetadataOutput *output = [AVCaptureMetadataOutput new];
        if (!input || ![session canAddInput:input]) {
            [self save:@"camera_error" fields:@{@"message": error.description ?: @"no usable input"}];
            return YES;
        }
        [session addInput:input];
        if (![session canAddOutput:output]) {
            [self save:@"camera_error" fields:@{@"message": @"metadata output unavailable"}];
            return YES;
        }
        [session addOutput:output];
        [output setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
        if (![output.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeQRCode]) {
            [self save:@"camera_error" fields:@{@"message": @"QR metadata unavailable"}];
            return YES;
        }
        output.metadataObjectTypes = @[AVMetadataObjectTypeQRCode];
        self.metadata = output;
        self.capture = session;
        [session startRunning];
        [self save:@"camera_started" fields:@{}];
    }
    return YES;
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if (manager != self.location) return;
    [self save:@"location_authorization" fields:@{@"status": @(manager.authorizationStatus)}];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (manager != self.location) return;
    if (![self.record[@"mode"] isEqualToString:@"location"]) return;
    for (CLLocation *point in locations) {
        [self save:@"location_callback" fields:@{@"latitude": @(point.coordinate.latitude),
            @"longitude": @(point.coordinate.longitude), @"altitude": @(point.altitude),
            @"horizontalAccuracy": @(point.horizontalAccuracy),
            @"verticalAccuracy": @(point.verticalAccuracy), @"speed": @(point.speed),
            @"course": @(point.course), @"timestamp": @([point.timestamp timeIntervalSince1970])}];
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    if (manager != self.location) return;
    [self save:@"location_error" fields:@{@"message": error.description}];
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray<AVMetadataObject *> *)objects fromConnection:(AVCaptureConnection *)connection {
    (void)connection;
    if (output != self.metadata) return;
    for (AVMetadataObject *object in objects) {
        if ([object isKindOfClass:AVMetadataMachineReadableCodeObject.class]) {
            NSString *message = ((AVMetadataMachineReadableCodeObject *)object).stringValue;
            [self save:@"camera_metadata" fields:@{@"message": message ?: @""}];
        }
    }
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(T52Probe.class)); }
}

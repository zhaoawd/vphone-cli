// Compile the production hooks with fake AVFoundation objects and a deterministic
// decoder. No camera, shared-memory file, or device service is opened.
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define CAMFIX_PRIVATE_H
#define AVCaptureSession VPhoneTestCaptureSession
#define AVCaptureInput VPhoneTestCaptureInput
#define AVCaptureOutput VPhoneTestCaptureOutput
#define AVCaptureMetadataOutput VPhoneTestMetadataOutput
#define AVMetadataObject VPhoneTestMetadataObject
#define AVMetadataMachineReadableCodeObject VPhoneTestCodeObject
#define CIDetector VPhoneTestQRDetector
#define CIImage VPhoneTestQRImage
#define CIFeature VPhoneTestQRFeature
typedef NSString *AVMetadataObjectType;
static NSString *const AVMetadataObjectTypeQRCode = @"org.iso.QRCode";

@interface AVCaptureInput : NSObject @end
@implementation AVCaptureInput @end
@interface AVCaptureOutput : NSObject
@property(nonatomic, readonly) NSArray *connections;
@end
@implementation AVCaptureOutput
- (NSArray *)connections { return @[]; }
@end
@interface AVCaptureMetadataOutput : AVCaptureOutput
@property(nonatomic, copy) NSArray *metadataObjectTypes;
- (NSArray *)availableMetadataObjectTypes;
- (void)setMetadataObjectsDelegate:(id)delegate queue:(dispatch_queue_t)queue;
@end
@implementation AVCaptureMetadataOutput
- (NSArray *)availableMetadataObjectTypes { return @[]; }
- (void)setMetadataObjectsDelegate:(id)delegate queue:(dispatch_queue_t)queue {
  (void)delegate; (void)queue;
}
@end
@interface AVCaptureSession : NSObject
@property(nonatomic, strong) NSMutableArray *outputs;
- (void)addOutput:(id)output;
- (void)addOutputWithNoConnections:(id)output;
- (void)removeOutput:(id)output;
- (void)startRunning;
- (void)stopRunning;
- (BOOL)isRunning;
@end
static BOOL testSessionDeallocated;
@implementation AVCaptureSession
- (instancetype)init { if ((self = [super init])) _outputs = [NSMutableArray array]; return self; }
- (void)addOutput:(id)output { [self.outputs addObject:output]; }
- (void)addOutputWithNoConnections:(id)output { [self.outputs addObject:output]; }
- (void)removeOutput:(id)output { [self.outputs removeObject:output]; }
- (void)startRunning {}
- (void)stopRunning {}
- (void)dealloc { [self stopRunning]; testSessionDeallocated = YES; }
// The other production CamFix hook forces this getter to YES. Metadata must
// track explicit start/stop intent rather than trust this value.
- (BOOL)isRunning { return YES; }
@end
@interface AVMetadataObject : NSObject
- (instancetype)initWithType:(AVMetadataObjectType)type time:(CMTime)time
                    duration:(CMTime)duration bounds:(CGRect)bounds
            optionalInfoDict:(NSDictionary *)optionalInfo
      originalMetadataObject:(AVMetadataObject *)original sourceCaptureInput:(AVCaptureInput *)input;
@end
@implementation AVMetadataObject
- (instancetype)initWithType:(AVMetadataObjectType)type time:(CMTime)time
                    duration:(CMTime)duration bounds:(CGRect)bounds
            optionalInfoDict:(NSDictionary *)optionalInfo
      originalMetadataObject:(AVMetadataObject *)original sourceCaptureInput:(AVCaptureInput *)input {
  (void)type; (void)time; (void)duration; (void)bounds; (void)optionalInfo; (void)original; (void)input;
  return [super init];
}
@end
@interface AVMetadataMachineReadableCodeObject : AVMetadataObject @end
@implementation AVMetadataMachineReadableCodeObject @end

static NSString *testPayload;
static uint64_t testFrame = 1;
static NSString *testPresentation = @"presentation-A";
@interface CIImage : NSObject
+ (instancetype)imageWithCGImage:(CGImageRef)image;
@end
@implementation CIImage
+ (instancetype)imageWithCGImage:(CGImageRef)image { (void)image; return [self new]; }
@end
@interface CIFeature : NSObject
@property(nonatomic, copy) NSString *messageString;
@end
@implementation CIFeature @end
@interface CIDetector : NSObject
+ (instancetype)detectorOfType:(NSString *)type context:(id)context options:(NSDictionary *)options;
- (NSArray *)featuresInImage:(CIImage *)image;
@end
@implementation CIDetector
+ (instancetype)detectorOfType:(NSString *)type context:(id)context options:(NSDictionary *)options {
  (void)type; (void)context; (void)options; return [self new];
}
- (NSArray *)featuresInImage:(CIImage *)image {
  (void)image;
  if (!testPayload) return @[];
  CIFeature *feature = [CIFeature new]; feature.messageString = testPayload;
  return @[feature];
}
@end

static void cfxlog(NSString *format, ...) { (void)format; }
static BOOL cfx_output_is_for_vcam(id output) { (void)output; return NO; }
static BOOL cfx_session_is_for_vcam(id session) { return [session isKindOfClass:AVCaptureSession.class]; }
static uint64_t cfx_shm_latest_frame_index(void) { return testFrame; }
static NSString *cfx_shm_presentation_id(void) { return testPresentation; }
static CGImageRef cfx_build_cgimage_from_shm(void) {
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(NULL, 1, 1, 8, 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGImageRef image = CGBitmapContextCreateImage(context);
  CGContextRelease(context); CGColorSpaceRelease(space);
  return image;
}
static Class testMetadataClass(NSString *name) {
  if ([name isEqual:@"AVCaptureSession"]) return AVCaptureSession.class;
  if ([name isEqual:@"AVCaptureMetadataOutput"]) return AVCaptureMetadataOutput.class;
  return Nil;
}
#define NSClassFromString testMetadataClass
#include "../CamFix/Session/CamFixMetadataOutput.m"

@interface MetadataDelegate : NSObject
@property(nonatomic) NSUInteger count;
@property(nonatomic, copy) NSString *lastPayload;
- (void)captureOutput:(id)output didOutputMetadataObjects:(NSArray *)objects fromConnection:(id)connection;
@end
@implementation MetadataDelegate
- (void)captureOutput:(id)output didOutputMetadataObjects:(NSArray *)objects fromConnection:(id)connection {
  (void)output; (void)connection;
  self.count += 1; self.lastPayload = [objects.firstObject stringValue];
}
@end

static int checks, failures;
#define CHECK(condition) do { checks++; if (!(condition)) { failures++; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); } } while (0)
static void tick(dispatch_queue_t queue) { cfx_drive_metadata_once(); dispatch_sync(queue, ^{}); }

int main(void) {
  @autoreleasepool {
    // Exercise the driver synchronously; disable only its clock, not its logic.
    cfx_metadata_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(0, 0));
    dispatch_source_set_timer(cfx_metadata_timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(cfx_metadata_timer);
    cfx_install_metadata_output_hooks();
    dispatch_queue_t queue = dispatch_queue_create("metadata-test-delegate", DISPATCH_QUEUE_SERIAL);
    AVCaptureSession *session = [AVCaptureSession new];
    AVCaptureMetadataOutput *output = [AVCaptureMetadataOutput new];
    MetadataDelegate *delegate = [MetadataDelegate new];
    [session addOutput:output];
    CHECK([[output availableMetadataObjectTypes] containsObject:AVMetadataObjectTypeQRCode]);
    [output setMetadataObjectsDelegate:delegate queue:queue];
    [output setMetadataObjectTypes:@[AVMetadataObjectTypeQRCode]];
    testPayload = @"QR-A";
    tick(queue);
    CHECK(delegate.count == 0);
    [session startRunning];
    tick(queue);
    CHECK(delegate.count == 1);
    testFrame++;
    tick(queue);
    CHECK(delegate.count == 1);
    testPayload = @"QR-B"; testFrame++;
    tick(queue);
    CHECK(delegate.count == 2 && [delegate.lastPayload isEqual:@"QR-B"]);
    testPresentation = @"presentation-B"; testFrame = 1;
    tick(queue);
    CHECK(delegate.count == 3);
    [session stopRunning];
    testPayload = @"QR-C"; testFrame++;
    tick(queue);
    CHECK(delegate.count == 3);
    [session startRunning];
    tick(queue);
    CHECK(delegate.count == 4 && [delegate.lastPayload isEqual:@"QR-C"]);
    [session startRunning];
    tick(queue);
    CHECK(delegate.count == 4);

    dispatch_suspend(queue);
    testPayload = @"QR-D"; testFrame++;
    cfx_drive_metadata_once();
    MetadataDelegate *replacement = [MetadataDelegate new];
    [output setMetadataObjectsDelegate:replacement queue:queue];
    dispatch_resume(queue); dispatch_sync(queue, ^{});
    CHECK(delegate.count == 4 && replacement.count == 0);
    tick(queue);
    CHECK(replacement.count == 1);

    dispatch_suspend(queue);
    testPayload = @"QR-E"; testFrame++;
    cfx_drive_metadata_once();
    [session stopRunning];
    dispatch_resume(queue); dispatch_sync(queue, ^{});
    CHECK(replacement.count == 1);
    [session startRunning];
    tick(queue);
    CHECK(replacement.count == 2);

    dispatch_suspend(queue);
    testPayload = @"QR-restart"; testFrame++;
    cfx_drive_metadata_once();
    [session stopRunning];
    [session startRunning];
    dispatch_resume(queue); dispatch_sync(queue, ^{});
    CHECK(replacement.count == 2);
    // Configure a different payload for the next existing assertion sequence.

    dispatch_suspend(queue);
    testPayload = @"QR-F"; testFrame++;
    cfx_drive_metadata_once();
    [output setMetadataObjectTypes:@[]];
    dispatch_resume(queue); dispatch_sync(queue, ^{});
    CHECK(replacement.count == 2);
    [output setMetadataObjectTypes:@[AVMetadataObjectTypeQRCode]];
    tick(queue);
    CHECK(replacement.count == 3);

    dispatch_suspend(queue);
    testPayload = @"QR-G"; testFrame++;
    cfx_drive_metadata_once();
    [session removeOutput:output];
    dispatch_resume(queue); dispatch_sync(queue, ^{});
    CHECK(replacement.count == 3);
    [session addOutputWithNoConnections:output];
    tick(queue);
    CHECK(replacement.count == 4);

    dispatch_suspend(queue);
    testPayload = @"QR-H"; testFrame++;
    cfx_drive_metadata_once();
    testPresentation = @"neutral-replacement";
    testPayload = nil; testFrame++;
    dispatch_resume(queue); dispatch_sync(queue, ^{});
    CHECK(replacement.count == 4);
    tick(queue);
    CHECK(replacement.count == 4);
    [output setMetadataObjectsDelegate:nil queue:NULL];
    __weak MetadataDelegate *weakDelegate;
    dispatch_suspend(queue);
    @autoreleasepool {
      MetadataDelegate *temporary = [MetadataDelegate new];
      weakDelegate = temporary;
      [output setMetadataObjectsDelegate:temporary queue:queue];
      testPayload = @"QR-weak"; testPresentation = @"presentation-weak"; testFrame++;
      cfx_drive_metadata_once();
    }
    CHECK(weakDelegate == nil);
    dispatch_resume(queue); dispatch_sync(queue, ^{});
    [output setMetadataObjectsDelegate:nil queue:NULL];
    testSessionDeallocated = NO;
    @autoreleasepool {
      AVCaptureSession *temporary = [AVCaptureSession new];
      [temporary startRunning];
    }
    CHECK(testSessionDeallocated);
    printf("%d metadata checks, %d failures\n", checks, failures);
  }
  return failures ? 1 : 0;
}

// MARK: - AVCaptureMetadataOutput QR delivery
//
// cameracaptured exposes the synthetic video device and preview frames, but
// it has no hardware metadata analyzer. AVFoundation therefore reports an
// empty availableMetadataObjectTypes array and throws when a client requests
// AVMetadataObjectTypeQRCode. Keep the public AVCaptureMetadataOutput contract
// intact for vcam-bound outputs: advertise QR, retain the requested types and
// deliver QR objects decoded from the same shared-memory camera frames. Each
// delegate/type configuration is one consumption window and receives at most
// one QR callback, fencing repeated static frames from duplicate submissions.

@interface AVMetadataObject (VPhonePrivateInit)
- (instancetype)initWithType:(AVMetadataObjectType)type
                        time:(CMTime)time
                    duration:(CMTime)duration
                      bounds:(CGRect)bounds
            optionalInfoDict:(NSDictionary *)optionalInfo
      originalMetadataObject:(AVMetadataObject *)original
          sourceCaptureInput:(AVCaptureInput *)input;
@end

@interface VPhoneQRMetadataObject : AVMetadataMachineReadableCodeObject {
  NSString *_vphoneStringValue;
}
- (instancetype)initWithStringValue:(NSString *)stringValue;
@end

@implementation VPhoneQRMetadataObject
- (instancetype)initWithStringValue:(NSString *)stringValue {
  self = [super initWithType:AVMetadataObjectTypeQRCode
                       time:kCMTimeZero
                   duration:kCMTimeInvalid
                     bounds:CGRectMake(0, 0, 1, 1)
           optionalInfoDict:nil
     originalMetadataObject:nil
         sourceCaptureInput:nil];
  if (self) _vphoneStringValue = [stringValue copy];
  return self;
}
- (NSString *)stringValue { return _vphoneStringValue; }
- (AVMetadataObjectType)type { return AVMetadataObjectTypeQRCode; }
- (CGRect)bounds { return CGRectMake(0, 0, 1, 1); }
- (NSArray *)corners { return @[]; }
@end

// AVCaptureMetadataOutput does not retain its delegate.  Mirroring that
// contract with OBJC_ASSOCIATION_ASSIGN leaves a dangling pointer when the
// scanner tears down while the 5 Hz metadata timer is still armed.  Loading
// that stale association into a strong local then crashes in objc_retain.
// Keep a retained holder whose value is zeroing-weak instead: the timer can
// safely promote a live delegate for one callback, or observe nil after
// teardown, without creating an output <-> delegate retain cycle.
@interface VPhoneWeakReference : NSObject
@property(nonatomic, weak) id value;
@end

@implementation VPhoneWeakReference
@end

static IMP cfx_orig_availableMetadataTypes = NULL;
static IMP cfx_orig_metadataTypes = NULL;
static IMP cfx_orig_setMetadataTypes = NULL;
static IMP cfx_orig_setMetadataDelegateQueue = NULL;
static const void *CFX_METADATA_TYPES_KEY = &CFX_METADATA_TYPES_KEY;
static const void *CFX_METADATA_DELEGATE_KEY = &CFX_METADATA_DELEGATE_KEY;
static const void *CFX_METADATA_QUEUE_KEY = &CFX_METADATA_QUEUE_KEY;
static const void *CFX_METADATA_LAST_FRAME_KEY = &CFX_METADATA_LAST_FRAME_KEY;
static const void *CFX_METADATA_DELIVERED_KEY = &CFX_METADATA_DELIVERED_KEY;
static NSHashTable *cfx_metadata_outputs = nil;
static dispatch_source_t cfx_metadata_timer = NULL;
static CIDetector *cfx_qr_detector = nil;

static id cfx_metadata_delegate(id output) {
  VPhoneWeakReference *reference =
      objc_getAssociatedObject(output, CFX_METADATA_DELEGATE_KEY);
  return reference.value;
}

static NSArray *cfx_availableMetadataTypes_hook(id self, SEL _cmd) {
  typedef NSArray *(*Fn)(id, SEL);
  NSArray *real = ((Fn)cfx_orig_availableMetadataTypes)(self, _cmd);
  if (!cfx_output_is_for_vcam(self)) return real;
  if ([real containsObject:AVMetadataObjectTypeQRCode]) return real;
  NSMutableArray *types = real ? [real mutableCopy] : [NSMutableArray array];
  [types addObject:AVMetadataObjectTypeQRCode];
  return types;
}

static NSArray *cfx_metadataTypes_hook(id self, SEL _cmd) {
  NSArray *stored = objc_getAssociatedObject(self, CFX_METADATA_TYPES_KEY);
  if (stored && cfx_output_is_for_vcam(self)) return stored;
  typedef NSArray *(*Fn)(id, SEL);
  return ((Fn)cfx_orig_metadataTypes)(self, _cmd);
}

static void cfx_setMetadataTypes_hook(id self, SEL _cmd, NSArray *types) {
  if (!cfx_output_is_for_vcam(self)) {
    typedef void (*Fn)(id, SEL, NSArray *);
    ((Fn)cfx_orig_setMetadataTypes)(self, _cmd, types);
    return;
  }
  NSMutableArray *accepted = [NSMutableArray array];
  for (id type in types ?: @[]) {
    if ([type isEqual:AVMetadataObjectTypeQRCode]) [accepted addObject:type];
  }
  objc_setAssociatedObject(self, CFX_METADATA_TYPES_KEY, accepted,
                           OBJC_ASSOCIATION_COPY_NONATOMIC);
  // A metadata type configuration starts a new scanner consumption window.
  // The same static QR is repeated at camera FPS, but AVCapture clients expect
  // to own the stop/retry lifecycle after the first callback.  Reset here so
  // a later scan configuration can consume one new frame without allowing the
  // current window to submit the same duty payload repeatedly.
  objc_setAssociatedObject(self, CFX_METADATA_DELIVERED_KEY, @NO,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  cfxlog(@"[metadata] accepted %lu/%lu requested type(s) for vcam output %p",
         (unsigned long)accepted.count, (unsigned long)types.count, self);
}

static uint64_t cfx_latest_frame_index(void) {
  if (!cfx_shm_open()) return 0;
  const vphone_vcam_shm_header_t *hdr = (const vphone_vcam_shm_header_t *)cfx_shm_base;
  return hdr->frame_index;
}

static NSString *cfx_decode_qr_from_shm(void) {
  CGImageRef image = cfx_build_cgimage_from_shm();
  if (!image) return nil;
  if (!cfx_qr_detector) {
    cfx_qr_detector = [CIDetector detectorOfType:CIDetectorTypeQRCode
                                         context:nil
                                         options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
  }
  CIImage *ciImage = [CIImage imageWithCGImage:image];
  CGImageRelease(image);
  for (CIFeature *feature in [cfx_qr_detector featuresInImage:ciImage]) {
    if ([feature respondsToSelector:@selector(messageString)]) {
      NSString *message = [feature valueForKey:@"messageString"];
      if (message.length > 0) return message;
    }
  }
  return nil;
}

static void cfx_drive_metadata_once(void) {
  NSArray *outputs = nil;
  @synchronized(cfx_metadata_outputs) {
    outputs = cfx_metadata_outputs.allObjects;
  }
  if (outputs.count == 0) return;
  uint64_t frameIndex = cfx_latest_frame_index();
  if (frameIndex == 0) return;

  NSMutableArray *eligible = [NSMutableArray array];
  for (id output in outputs) {
    if (!cfx_output_is_for_vcam(output)) continue;
    NSArray *types = objc_getAssociatedObject(output, CFX_METADATA_TYPES_KEY);
    id delegate = cfx_metadata_delegate(output);
    NSNumber *last = objc_getAssociatedObject(output, CFX_METADATA_LAST_FRAME_KEY);
    NSNumber *delivered = objc_getAssociatedObject(output, CFX_METADATA_DELIVERED_KEY);
    if (![types containsObject:AVMetadataObjectTypeQRCode] || !delegate ||
        delivered.boolValue || last.unsignedLongLongValue == frameIndex) continue;
    objc_setAssociatedObject(output, CFX_METADATA_LAST_FRAME_KEY,
                             @(frameIndex), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [eligible addObject:output];
  }
  if (eligible.count == 0) return;

  NSString *payload = cfx_decode_qr_from_shm();
  if (payload.length == 0) return;
  VPhoneQRMetadataObject *metadata =
      [[VPhoneQRMetadataObject alloc] initWithStringValue:payload];

  for (id output in eligible) {
    id delegate = cfx_metadata_delegate(output);
    dispatch_queue_t queue = objc_getAssociatedObject(output, CFX_METADATA_QUEUE_KEY);
    SEL callback = @selector(captureOutput:didOutputMetadataObjects:fromConnection:);
    if (!delegate || ![delegate respondsToSelector:callback]) continue;
    id connection = nil;
    @try { connection = [[output connections] firstObject]; }
    @catch (NSException *e) {}
    // Fence before dispatch: the delegate can synchronously stop/reconfigure
    // its session, while the 5 Hz driver continues observing new shm frames.
    // Marking the window consumed first guarantees at-most-once delivery.
    objc_setAssociatedObject(output, CFX_METADATA_DELIVERED_KEY, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(queue ?: dispatch_get_main_queue(), ^{
      ((void (*)(id, SEL, id, id, id))objc_msgSend)(
          delegate, callback, output, @[metadata], connection);
    });
    cfxlog(@"[metadata] delivered QR frame=%llu output=%p",
           frameIndex, output);
  }
}

static void cfx_start_metadata_timer(void) {
  if (cfx_metadata_timer) return;
  dispatch_queue_t queue = dispatch_queue_create(
      "com.vphone.camfix.metadata", DISPATCH_QUEUE_SERIAL);
  cfx_metadata_timer = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
  dispatch_source_set_timer(cfx_metadata_timer,
                            dispatch_time(DISPATCH_TIME_NOW, 0),
                            200000000ull, 20000000ull);
  dispatch_source_set_event_handler(cfx_metadata_timer, ^{
    @autoreleasepool { cfx_drive_metadata_once(); }
  });
  dispatch_resume(cfx_metadata_timer);
  cfxlog(@"metadata QR driver armed (5 Hz)");
}

static void cfx_setMetadataDelegateQueue_hook(id self, SEL _cmd,
                                               id delegate,
                                               dispatch_queue_t queue) {
  typedef void (*Fn)(id, SEL, id, dispatch_queue_t);
  ((Fn)cfx_orig_setMetadataDelegateQueue)(self, _cmd, delegate, queue);
  VPhoneWeakReference *reference = nil;
  if (delegate) {
    reference = [VPhoneWeakReference new];
    reference.value = delegate;
  }
  objc_setAssociatedObject(self, CFX_METADATA_DELEGATE_KEY, reference,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(self, CFX_METADATA_QUEUE_KEY, delegate ? queue : nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(self, CFX_METADATA_DELIVERED_KEY, @NO,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  @synchronized(cfx_metadata_outputs) {
    if (delegate) [cfx_metadata_outputs addObject:self];
    else [cfx_metadata_outputs removeObject:self];
  }
  cfx_start_metadata_timer();
}

static void cfx_install_metadata_output_hooks(void) {
  Class cls = NSClassFromString(@"AVCaptureMetadataOutput");
  if (!cls) { cfxlog(@"AVCaptureMetadataOutput missing"); return; }
  if (!cfx_metadata_outputs) cfx_metadata_outputs = [NSHashTable weakObjectsHashTable];
  Method available = class_getInstanceMethod(cls, @selector(availableMetadataObjectTypes));
  Method getTypes = class_getInstanceMethod(cls, @selector(metadataObjectTypes));
  Method setTypes = class_getInstanceMethod(cls, @selector(setMetadataObjectTypes:));
  Method setDelegate = class_getInstanceMethod(
      cls, @selector(setMetadataObjectsDelegate:queue:));
  if (!available || !getTypes || !setTypes || !setDelegate) {
    cfxlog(@"metadata output hook method missing");
    return;
  }
  cfx_orig_availableMetadataTypes = method_setImplementation(
      available, (IMP)cfx_availableMetadataTypes_hook);
  cfx_orig_metadataTypes = method_setImplementation(
      getTypes, (IMP)cfx_metadataTypes_hook);
  cfx_orig_setMetadataTypes = method_setImplementation(
      setTypes, (IMP)cfx_setMetadataTypes_hook);
  cfx_orig_setMetadataDelegateQueue = method_setImplementation(
      setDelegate, (IMP)cfx_setMetadataDelegateQueue_hook);
  cfxlog(@"installed AVCaptureMetadataOutput QR hooks");
}


// AVCaptureMetadataOutput QR delivery for vcam-bound sessions.
//
// cameracaptured exposes the synthetic video device and preview frames, but
// it has no hardware metadata analyzer. AVFoundation therefore reports an
// empty availableMetadataObjectTypes array and throws when a client requests
// AVMetadataObjectTypeQRCode. Keep the public AVCaptureMetadataOutput contract
// intact for vcam-bound outputs: advertise QR, retain the requested types and
// deliver QR objects decoded from the same shared-memory camera frames. Each
// presentation/content pair is delivered once per explicit running session
// and output configuration. Repeated static frames do not resubmit a QR.

#import "CamFixPrivate.h"
#import "CamFixSessionReference.h"
#import <CoreImage/CoreImage.h>

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

// AVCaptureMetadataOutput does not retain its delegate. Mirroring that
// contract with OBJC_ASSOCIATION_ASSIGN leaves a dangling pointer when the
// scanner tears down while the 5 Hz metadata timer is still armed. Loading
// that stale association into a strong local then crashes in objc_retain.
// Keep a retained holder whose value is zeroing-weak instead: the timer can
// safely promote a live delegate for one callback, or observe nil after
// teardown, without creating an output <-> delegate retain cycle.
@interface VPhoneWeakReference : NSObject
@property(nonatomic, weak) id value;
@end

@implementation VPhoneWeakReference
@end

@interface VPhoneMetadataSessionState : NSObject
@property(nonatomic) BOOL running;
@property(nonatomic) uint64_t epoch;
@end
@implementation VPhoneMetadataSessionState
@end

@interface VPhoneMetadataOutputState : NSObject
@property(nonatomic) uint64_t revision;
@property(nonatomic, copy) NSString *seenFrame;
@property(nonatomic, copy) NSString *deliveredPresentation;
@property(nonatomic, copy) NSString *deliveredPayload;
@property(nonatomic) uint64_t deliveredEpoch;
@end
@implementation VPhoneMetadataOutputState
@end

@interface VPhoneMetadataDelivery : NSObject
@property(nonatomic, weak) id output;
@property(nonatomic, weak) id session;
@property(nonatomic, weak) id delegate;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) uint64_t revision;
@property(nonatomic) uint64_t epoch;
@property(nonatomic, copy) NSString *presentation;
@end
@implementation VPhoneMetadataDelivery
@end

static IMP cfx_orig_availableMetadataTypes = NULL;
static IMP cfx_orig_metadataTypes = NULL;
static IMP cfx_orig_setMetadataTypes = NULL;
static IMP cfx_orig_setMetadataDelegateQueue = NULL;
static IMP cfx_orig_session_addOutput = NULL;
static IMP cfx_orig_session_addOutputNoConn = NULL;
static IMP cfx_orig_session_removeOutput = NULL;
static IMP cfx_orig_session_startRunning = NULL;
static IMP cfx_orig_session_stopRunning = NULL;
static const void *CFX_METADATA_TYPES_KEY = &CFX_METADATA_TYPES_KEY;
static const void *CFX_METADATA_DELEGATE_KEY = &CFX_METADATA_DELEGATE_KEY;
static const void *CFX_METADATA_QUEUE_KEY = &CFX_METADATA_QUEUE_KEY;
static const void *CFX_METADATA_SESSION_KEY = &CFX_METADATA_SESSION_KEY;
static const void *CFX_METADATA_STATE_KEY = &CFX_METADATA_STATE_KEY;
static const void *CFX_METADATA_SESSION_STATE_KEY = &CFX_METADATA_SESSION_STATE_KEY;
static NSHashTable *cfx_metadata_outputs = nil;
static dispatch_source_t cfx_metadata_timer = NULL;
static CIDetector *cfx_qr_detector = nil;

// Callers hold @synchronized(output); configuration and queued callback
// validation use the same revision, including detach/re-attach of an output.
static VPhoneMetadataOutputState *cfx_metadata_state(id output) {
  VPhoneMetadataOutputState *state = objc_getAssociatedObject(output, CFX_METADATA_STATE_KEY);
  if (!state) {
    state = [VPhoneMetadataOutputState new];
    objc_setAssociatedObject(output, CFX_METADATA_STATE_KEY, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return state;
}

static void cfx_metadata_invalidate(id output) {
  VPhoneMetadataOutputState *state = cfx_metadata_state(output);
  state.revision++;
  state.seenFrame = nil;
  state.deliveredPresentation = nil;
  state.deliveredPayload = nil;
}

static BOOL cfx_metadata_session_running(id session, uint64_t *epoch) {
  if (!session) return NO;
  @synchronized(session) {
    VPhoneMetadataSessionState *state = objc_getAssociatedObject(session, CFX_METADATA_SESSION_STATE_KEY);
    if (epoch) *epoch = state.epoch;
    return state.running;
  }
}

static void cfx_metadata_set_session_running(id session, BOOL running) {
  @synchronized(session) {
    VPhoneMetadataSessionState *state = objc_getAssociatedObject(session, CFX_METADATA_SESSION_STATE_KEY);
    if (!state) {
      state = [VPhoneMetadataSessionState new];
      objc_setAssociatedObject(session, CFX_METADATA_SESSION_STATE_KEY, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (state.running != running) state.epoch++;
    state.running = running;
  }
}

static void cfx_metadata_startRunning_hook(id self, SEL _cmd) {
  ((void (*)(id, SEL))cfx_orig_session_startRunning)(self, _cmd);
  id live = cfx_load_live_session(self);
  if (live) cfx_metadata_set_session_running(live, YES);
}

static void cfx_metadata_stopRunning_hook(id self, SEL _cmd) {
  // Invalidate callbacks before the potentially blocking original call. Other
  // CamFix hooks deliberately override isRunning/_setRunning for preview.
  id live = cfx_load_live_session(self);
  if (live) cfx_metadata_set_session_running(live, NO);
  ((void (*)(id, SEL))cfx_orig_session_stopRunning)(self, _cmd);
}

static id cfx_metadata_session(id output) {
  VPhoneWeakReference *reference = objc_getAssociatedObject(output, CFX_METADATA_SESSION_KEY);
  return reference.value;
}

static id cfx_metadata_delegate(id output) {
  VPhoneWeakReference *reference =
      objc_getAssociatedObject(output, CFX_METADATA_DELEGATE_KEY);
  return reference.value;
}

static BOOL cfx_metadata_output_is_for_vcam(id output) {
  if (cfx_output_is_for_vcam(output)) return YES;
  VPhoneWeakReference *reference =
      objc_getAssociatedObject(output, CFX_METADATA_SESSION_KEY);
  id session = reference.value;
  if (session && cfx_session_is_for_vcam(session)) return YES;
  return NO;
}

static void cfx_bind_output_to_session(id output, id session) {
  if (!output) return;
  VPhoneWeakReference *reference = nil;
  if (session) {
    reference = [VPhoneWeakReference new];
    reference.value = session;
  }
  @synchronized(output) {
    objc_setAssociatedObject(output, CFX_METADATA_SESSION_KEY, reference,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cfx_metadata_invalidate(output);
  }
}

static void cfx_session_addOutput_hook(id self, SEL _cmd, id output) {
  cfx_bind_output_to_session(output, self);
  typedef void (*Fn)(id, SEL, id);
  ((Fn)cfx_orig_session_addOutput)(self, _cmd, output);
}

static void cfx_session_addOutputNoConn_hook(id self, SEL _cmd, id output) {
  cfx_bind_output_to_session(output, self);
  typedef void (*Fn)(id, SEL, id);
  ((Fn)cfx_orig_session_addOutputNoConn)(self, _cmd, output);
}

static void cfx_session_removeOutput_hook(id self, SEL _cmd, id output) {
  cfx_bind_output_to_session(output, nil);
  typedef void (*Fn)(id, SEL, id);
  ((Fn)cfx_orig_session_removeOutput)(self, _cmd, output);
}

static NSArray *cfx_availableMetadataTypes_hook(id self, SEL _cmd) {
  typedef NSArray *(*Fn)(id, SEL);
  NSArray *real = ((Fn)cfx_orig_availableMetadataTypes)(self, _cmd);
  if (!cfx_metadata_output_is_for_vcam(self)) return real;
  if ([real containsObject:AVMetadataObjectTypeQRCode]) return real;
  NSMutableArray *types = real ? [real mutableCopy] : [NSMutableArray array];
  [types addObject:AVMetadataObjectTypeQRCode];
  return types;
}

static NSArray *cfx_metadataTypes_hook(id self, SEL _cmd) {
  NSArray *stored = objc_getAssociatedObject(self, CFX_METADATA_TYPES_KEY);
  if (stored && cfx_metadata_output_is_for_vcam(self)) return stored;
  typedef NSArray *(*Fn)(id, SEL);
  return ((Fn)cfx_orig_metadataTypes)(self, _cmd);
}

static void cfx_setMetadataTypes_hook(id self, SEL _cmd, NSArray *types) {
  if (!cfx_metadata_output_is_for_vcam(self)) {
    typedef void (*Fn)(id, SEL, NSArray *);
    ((Fn)cfx_orig_setMetadataTypes)(self, _cmd, types);
    return;
  }
  NSMutableArray *accepted = [NSMutableArray array];
  for (id type in types ?: @[]) {
    if ([type isEqual:AVMetadataObjectTypeQRCode]) [accepted addObject:type];
  }
  @synchronized(self) {
    objc_setAssociatedObject(self, CFX_METADATA_TYPES_KEY, accepted,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    cfx_metadata_invalidate(self);
  }
  cfxlog(@"[metadata] accepted %lu/%lu requested type(s) for vcam output %p",
         (unsigned long)accepted.count, (unsigned long)types.count, self);
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
  uint64_t frameIndex = cfx_shm_latest_frame_index();
  NSString *presentation = cfx_shm_presentation_id();
  if (frameIndex == 0 || presentation.length == 0) return;

  NSMutableArray *eligible = [NSMutableArray array];
  for (id output in outputs) {
    if (!cfx_metadata_output_is_for_vcam(output)) continue;
    id session = cfx_metadata_session(output);
    uint64_t epoch = 0;
    if (!cfx_metadata_session_running(session, &epoch)) continue;
    @synchronized(output) {
      NSArray *types = objc_getAssociatedObject(output, CFX_METADATA_TYPES_KEY);
      id delegate = cfx_metadata_delegate(output);
      if (![types containsObject:AVMetadataObjectTypeQRCode] || !delegate) continue;
      VPhoneMetadataOutputState *state = cfx_metadata_state(output);
      NSString *frame = [NSString stringWithFormat:@"%@/%llu/%llu", presentation, epoch, frameIndex];
      if ([state.seenFrame isEqual:frame]) continue;
      state.seenFrame = frame;
      VPhoneMetadataDelivery *delivery = [VPhoneMetadataDelivery new];
      delivery.output = output; delivery.session = session; delivery.delegate = delegate;
      delivery.queue = objc_getAssociatedObject(output, CFX_METADATA_QUEUE_KEY) ?: dispatch_get_main_queue();
      delivery.revision = state.revision; delivery.epoch = epoch; delivery.presentation = presentation;
      [eligible addObject:delivery];
    }
  }
  if (eligible.count == 0) return;

  NSString *payload = cfx_decode_qr_from_shm();
  if (payload.length == 0 || ![presentation isEqual:cfx_shm_presentation_id()]) return;
  VPhoneQRMetadataObject *metadata =
      [[VPhoneQRMetadataObject alloc] initWithStringValue:payload];

  for (VPhoneMetadataDelivery *delivery in eligible) {
    id output = delivery.output;
    id delegate = delivery.delegate;
    SEL callback = @selector(captureOutput:didOutputMetadataObjects:fromConnection:);
    if (!output || !delegate || ![delegate respondsToSelector:callback]) continue;
    @synchronized(output) {
      VPhoneMetadataOutputState *state = cfx_metadata_state(output);
      if (state.revision != delivery.revision) continue;
      if (state.deliveredEpoch == delivery.epoch &&
          [state.deliveredPresentation isEqual:presentation] &&
          [state.deliveredPayload isEqual:payload]) continue;
      state.deliveredEpoch = delivery.epoch;
      state.deliveredPresentation = presentation;
      state.deliveredPayload = payload;
    }
    id connection = nil;
    @try { connection = [[output connections] firstObject]; }
    @catch (NSException *e) {}
    dispatch_async(delivery.queue, ^{
      id output = delivery.output;
      id delegate = delivery.delegate;
      id session = delivery.session;
      uint64_t epoch = 0;
      if (!output || !delegate || !cfx_metadata_session_running(session, &epoch) ||
          epoch != delivery.epoch || ![delivery.presentation isEqual:cfx_shm_presentation_id()]) return;
      @synchronized(output) {
        NSArray *types = objc_getAssociatedObject(output, CFX_METADATA_TYPES_KEY);
        if (cfx_metadata_state(output).revision != delivery.revision ||
            cfx_metadata_session(output) != session || cfx_metadata_delegate(output) != delegate ||
            ![types containsObject:AVMetadataObjectTypeQRCode]) return;
      }
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
  @synchronized(self) {
    objc_setAssociatedObject(self, CFX_METADATA_DELEGATE_KEY, reference,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, CFX_METADATA_QUEUE_KEY, delegate ? queue : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cfx_metadata_invalidate(self);
  }
  @synchronized(cfx_metadata_outputs) {
    if (delegate) [cfx_metadata_outputs addObject:self];
    else [cfx_metadata_outputs removeObject:self];
  }
  cfx_start_metadata_timer();
}

void cfx_install_metadata_output_hooks(void) {
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

  Class sessCls = NSClassFromString(@"AVCaptureSession");
  if (sessCls) {
    Method start = class_getInstanceMethod(sessCls, @selector(startRunning));
    Method stop = class_getInstanceMethod(sessCls, @selector(stopRunning));
    if (start) cfx_orig_session_startRunning = method_setImplementation(start, (IMP)cfx_metadata_startRunning_hook);
    if (stop) cfx_orig_session_stopRunning = method_setImplementation(stop, (IMP)cfx_metadata_stopRunning_hook);
    Method addOut = class_getInstanceMethod(sessCls, @selector(addOutput:));
    Method addOutNoConn = class_getInstanceMethod(
        sessCls, @selector(addOutputWithNoConnections:));
    Method remOut = class_getInstanceMethod(sessCls, @selector(removeOutput:));
    if (addOut) {
      cfx_orig_session_addOutput = method_setImplementation(
          addOut, (IMP)cfx_session_addOutput_hook);
    }
    if (addOutNoConn) {
      cfx_orig_session_addOutputNoConn = method_setImplementation(
          addOutNoConn, (IMP)cfx_session_addOutputNoConn_hook);
    }
    if (remOut) {
      cfx_orig_session_removeOutput = method_setImplementation(
          remOut, (IMP)cfx_session_removeOutput_hook);
    }
  }
  cfxlog(@"installed AVCaptureMetadataOutput QR hooks");
}

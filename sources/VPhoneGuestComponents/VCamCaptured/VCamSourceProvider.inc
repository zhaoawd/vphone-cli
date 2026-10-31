// MARK: - source backing provider

#include <dispatch/dispatch.h>

static NSString *const kVccSynthUniqueID = @"vphone:vcam:0";
static IMP vcc_source_provider_original = NULL;
static IMP vcc_shared_source_provider_original = NULL;
static id vcc_source_provider_backing = nil;
static id vcc_source_provider_fallback = nil;
static dispatch_once_t vcc_source_provider_fallback_once;

static id vcc_shared_source_provider(id self, SEL selector) {
  typedef id (*Getter)(id, SEL);
  id real = ((Getter)vcc_shared_source_provider_original)(self, selector);
  if (real) return real;
  // The native factory leaves its shared instance nil when it cannot build
  // hardware source information. Give the existing getter hook a receiver;
  // preserve native instances whenever the factory can supply one. This does
  // not write the framework's global instance or its private ivars.
  dispatch_once(&vcc_source_provider_fallback_once, ^{
    vcc_source_provider_fallback = [[self alloc] init];
    vcc_log(@"  native source provider fallback = %p (shared provider nil)", vcc_source_provider_fallback);
  });
  return vcc_source_provider_fallback;
}

static id vcc_source_backings(id self, SEL selector) {
  typedef id (*Getter)(id, SEL);
  id real = ((Getter)vcc_source_provider_original)(self, selector);
  if (real && ![real isKindOfClass:NSArray.class]) return real;
  NSMutableArray *result = [NSMutableArray array];
  for (id backing in real) {
    id attributes = [backing respondsToSelector:@selector(attributes)]
        ? ((id (*)(id, SEL))objc_msgSend)(backing, @selector(attributes)) : nil;
    if ([attributes isKindOfClass:NSDictionary.class] &&
        [attributes[@"UniqueID"] isEqual:kVccSynthUniqueID]) continue;
    [result addObject:backing];
  }
  [result addObject:vcc_source_provider_backing];
  return result;
}

static BOOL vcc_provider_method_is_getter(Method method) {
  if (!method || method_getNumberOfArguments(method) != 2) return NO;
  char *returnType = method_copyReturnType(method);
  BOOL valid = returnType && strcmp(returnType, "@") == 0;
  free(returnType);
  return valid;
}

static BOOL vcc_install_source_provider(Class provider, id backing) {
  if (vcc_source_provider_original) return YES;
  Method method = provider ? class_getInstanceMethod(provider, @selector(sourceBackings)) : NULL;
  Method shared = provider ? class_getClassMethod(provider, NSSelectorFromString(@"sharedCaptureSourceBackingsProvider")) : NULL;
  if (!backing || !vcc_provider_method_is_getter(method) || !vcc_provider_method_is_getter(shared)) return NO;
  vcc_source_provider_backing = backing;
  vcc_source_provider_original = method_getImplementation(method);
  vcc_shared_source_provider_original = method_getImplementation(shared);
  method_setImplementation(method, (IMP)vcc_source_backings);
  method_setImplementation(shared, (IMP)vcc_shared_source_provider);
  return YES;
}

// MARK: - source backing provider

static NSString *const kVccSynthUniqueID = @"vphone:vcam:0";
static IMP vcc_source_provider_original = NULL;
static id vcc_source_provider_backing = nil;

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

static BOOL vcc_install_source_provider(Class provider, id backing) {
  if (vcc_source_provider_original) return YES;
  Method method = provider ? class_getInstanceMethod(provider, @selector(sourceBackings)) : NULL;
  if (!method || !backing || method_getNumberOfArguments(method) != 2) return NO;
  char *returnType = method_copyReturnType(method);
  BOOL valid = returnType && strcmp(returnType, "@") == 0;
  free(returnType);
  if (!valid) return NO;
  vcc_source_provider_backing = backing;
  vcc_source_provider_original = method_getImplementation(method);
  method_setImplementation(method, (IMP)vcc_source_backings);
  return YES;
}

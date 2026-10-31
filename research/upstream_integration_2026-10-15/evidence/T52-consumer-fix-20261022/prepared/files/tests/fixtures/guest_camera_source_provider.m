#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include "../../sources/VPhoneGuestComponents/VCamCaptured/VCamSourceProvider.inc"

@interface TestBacking : NSObject
@property(nonatomic, strong) NSDictionary *attributes;
@end
@implementation TestBacking
@end

@interface TestProvider : NSObject
@property(nonatomic, strong) NSArray *real;
- (NSArray *)sourceBackings;
@end
@implementation TestProvider
- (NSArray *)sourceBackings { return self.real; }
@end

static TestBacking *backing(NSString *uid) {
  TestBacking *result = [TestBacking new]; result.attributes = @{@"UniqueID": uid}; return result;
}

#define CHECK(value) do { if (!(value)) { fprintf(stderr, "check failed at %d: %s\n", __LINE__, #value); return 1; } } while (0)

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 2) return 64;
    TestProvider *provider = [TestProvider new];
    TestBacking *synthetic = backing(kVccSynthUniqueID);
    TestBacking *native = backing(@"native-camera");
    if (strcmp(argv[1], "nil") == 0) provider.real = nil;
    else if (strcmp(argv[1], "empty") == 0) provider.real = @[];
    else if (strcmp(argv[1], "native") == 0) provider.real = @[native];
    else if (strcmp(argv[1], "stale") == 0) provider.real = @[backing(kVccSynthUniqueID), native, backing(kVccSynthUniqueID)];
    else return 65;
    NSArray *original = provider.real;
    CHECK([provider sourceBackings] == original);
    CHECK(!vcc_install_source_provider(NSObject.class, synthetic));
    CHECK(vcc_install_source_provider(TestProvider.class, synthetic));
    CHECK(vcc_install_source_provider(TestProvider.class, synthetic));
    NSArray *result = [provider sourceBackings];
    BOOL needsNative = strcmp(argv[1], "native") == 0 || strcmp(argv[1], "stale") == 0;
    CHECK(result.count == (needsNative ? 2 : 1));
    CHECK(result.lastObject == synthetic);
    if (needsNative) CHECK(result.firstObject == native);
    CHECK(provider.real == original);
    CHECK([[provider sourceBackings] isEqual:result]);
    return 0;
  }
}

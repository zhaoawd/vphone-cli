#import <Foundation/Foundation.h>
#include <assert.h>
extern BOOL vpInstallAlwaysOnWakePolicyForClass(Class, NSString *(*)(int), BOOL (*)(void));
extern BOOL vpInstallAlwaysOnBacklightPolicyForClass(Class, NSString *(*)(NSInteger), BOOL (*)(NSInteger), NSInteger (*)(NSString *), NSString *(*)(NSInteger), BOOL (*)(void));
// Production's provider and log are linked by FoldDisplayPanel/Support.
BOOL vpPanelIsAlwaysOn(void) { return NO; }
void vpFoldDisplayLog(NSString *line) { (void)line; }
static BOOL alwaysOn;
static NSDictionary *received;
static int receivedSource;
static BOOL state(void) { return alwaysOn; }
static NSString *describe(int source) { return source == 99 ? @"DisplayContentModeTransition" : @"LockButton"; }
static NSString *describeBacklightSource(NSInteger source) { return source == 123 ? @"display content mode transition" : @"lock button"; }
static BOOL active(NSInteger value) { return value == 7 || value == 8; }
static NSInteger fromString(NSString *value) { return [value isEqualToString:@"inactive"] ? 42 : 0; }
static NSString *describeState(NSInteger value) { return value == 42 ? @"inactive" : @"other"; }
static NSInteger invalidInactive(NSString *value) { (void)value; return 7; }
static NSInteger receivedState, receivedFrom, receivedBacklightSource;
static BOOL receivedAnimated;
@interface FoldBacklightFixture : NSObject
- (void)_setBacklightState:(NSInteger)value fromBacklightState:(NSInteger)from source:(NSInteger)source animated:(BOOL)animated completion:(void (^)(void))completion;
@end
@implementation FoldBacklightFixture
- (void)_setBacklightState:(NSInteger)value fromBacklightState:(NSInteger)from source:(NSInteger)source animated:(BOOL)animated completion:(void (^)(void))completion {
    receivedState=value; receivedFrom=from; receivedBacklightSource=source; receivedAnimated=animated;
    if (completion) completion();
}
@end
@interface FoldWakeFixture : NSObject
- (BOOL)unlockUIFromSource:(int)source withOptions:(NSDictionary *)options;
- (BOOL)unlockUIFromSource:(int)source withOptions:(NSDictionary *)options completion:(void (^)(void))completion;
@end
@implementation FoldWakeFixture
- (BOOL)unlockUIFromSource:(int)source withOptions:(NSDictionary *)options {
    return [self unlockUIFromSource:source withOptions:options completion:nil];
}
- (BOOL)unlockUIFromSource:(int)source withOptions:(NSDictionary *)options completion:(void (^)(void))completion {
    if(completion)completion();
    received = options; receivedSource = source; return YES;
}
@end
@interface FoldWakeWrongABI : NSObject
- (void)unlockUIFromSource:(int)source withOptions:(NSDictionary *)options;
- (void)unlockUIFromSource:(int)source withOptions:(NSDictionary *)options completion:(void (^)(void))completion;
@end
@implementation FoldWakeWrongABI
- (void)unlockUIFromSource:(int)source withOptions:(NSDictionary *)options { abort(); }
- (void)unlockUIFromSource:(int)source withOptions:(NSDictionary *)options completion:(void (^)(void))completion { abort(); }
@end
int main(void) { @autoreleasepool {
    assert(!vpInstallAlwaysOnWakePolicyForClass(FoldWakeWrongABI.class,describe,state));
    assert(vpInstallAlwaysOnWakePolicyForClass(FoldWakeFixture.class,describe,state));
    FoldWakeFixture *fixture = [FoldWakeFixture new];
    NSDictionary *options = @{@"SBUIUnlockOptionsTurnOnScreenFirstKey":@YES,@"OtherOption":@7};
    for (int dimmed=0;dimmed<2;dimmed++) for (int source=98;source<=99;source++) {
        alwaysOn=dimmed;
        assert([fixture unlockUIFromSource:source withOptions:options]);
        assert(receivedSource==source && [received[@"OtherOption"] isEqual:@7]);
        assert([received[@"SBUIUnlockOptionsTurnOnScreenFirstKey"] boolValue]==!(dimmed&&source==99));
        assert([received[@"SBUIUnlockOptionsNoBacklightChangesKey"] boolValue]==(dimmed&&source==99));
        assert([received[@"SBUIUnlockOptionsOnlyWakeToActionsKey"] boolValue]==(dimmed&&source==99));
        assert([received[@"SBUIUnlockOptionsSuppressingWakeToKey"] boolValue]==(dimmed&&source==99));
        assert([options[@"SBUIUnlockOptionsTurnOnScreenFirstKey"] boolValue]);
    }
    __block BOOL completed=NO;
    assert([fixture unlockUIFromSource:99 withOptions:options completion:^{completed=YES;}]);
    assert(completed);
    assert(!vpInstallAlwaysOnBacklightPolicyForClass(FoldWakeWrongABI.class, describeBacklightSource, active, fromString, describeState, state));
    assert(!vpInstallAlwaysOnBacklightPolicyForClass(FoldBacklightFixture.class, describeBacklightSource, active, invalidInactive, describeState, state));
    assert(vpInstallAlwaysOnBacklightPolicyForClass(FoldBacklightFixture.class, describeBacklightSource, active, fromString, describeState, state));
    FoldBacklightFixture *backlight=[FoldBacklightFixture new];
    for (int dimmed=0;dimmed<2;dimmed++) for (NSInteger source=122;source<=123;source++) for (NSInteger value=6;value<=8;value++) {
        alwaysOn=dimmed; completed=NO;
        [backlight _setBacklightState:value fromBacklightState:42 source:source animated:YES completion:^{completed=YES;}];
        assert(receivedState==((dimmed && source==123 && active(value)) ? 42 : value));
        assert(receivedFrom==42 && receivedBacklightSource==source && receivedAnimated && completed);
    }
    puts("FoldDisplay wake: AOD unlock and independent backlight preserved; other sources, true-off, completion, ABI and native state admission passed");
} }

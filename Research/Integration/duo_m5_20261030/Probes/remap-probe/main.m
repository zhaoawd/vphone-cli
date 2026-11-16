#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/loader.h>
#import <spawn.h>
#import <sys/sysctl.h>
#import <sys/wait.h>
#import <unistd.h>

extern int remap_main_marker(void);
extern int remap_framework_marker(void);
extern char **environ;
static NSMutableDictionary *report;
static NSURL *documents;

static NSString *hex(vm_address_t value) { return [NSString stringWithFormat:@"0x%llx", (unsigned long long)value]; }
static void save(void) {
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL]
        writeToURL:[documents URLByAppendingPathComponent:@"remap-probe.json"] atomically:YES];
}
static NSDictionary *region(vm_address_t point) {
    vm_address_t address = point;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
                                      (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    BOOL contains = kr == KERN_SUCCESS && address <= point && point - address < size;
    return @{@"result": @(kr), @"contains": @(contains), @"base": hex(address), @"size": @(size),
             @"current": @(contains ? info.protection : -1), @"maximum": @(contains ? info.max_protection : -1)};
}
static BOOL executable(NSDictionary *r) {
    int rx = VM_PROT_READ | VM_PROT_EXECUTE;
    return [r[@"contains"] boolValue] && ([r[@"current"] intValue] & rx) == rx && ([r[@"maximum"] intValue] & rx) == rx;
}
static BOOL textRange(void *function, vm_address_t *start, vm_size_t *size, NSString **image) {
    Dl_info info = {0};
    if (!dladdr(function, &info)) return NO;
    const struct mach_header_64 *header = info.dli_fbase;
    if (header->magic != MH_MAGIC_64) return NO;
    *image = @(info.dli_fname);
    const struct load_command *lc = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const void *)lc;
            if (strcmp(segment->segname, "__TEXT") == 0 && segment->fileoff == 0) {
                *start = (vm_address_t)header;
                *size = segment->vmsize;
                return YES;
            }
        }
        lc = (const void *)((const char *)lc + lc->cmdsize);
    }
    return NO;
}
static void remapCase(NSString *imageName, int (*function)(void), int expected,
                      BOOL whole, BOOL copy, BOOL fixed, int repetitions) {
    NSMutableArray *cases = report[@"cases"];
    NSMutableDictionary *row = [@{@"image": imageName, @"wholeText": @(whole), @"privateCopy": @(copy),
        @"fixedOverwrite": @(fixed), @"repetitions": @(repetitions), @"aliases": [NSMutableArray array], @"passed": @NO} mutableCopy];
    [cases addObject:row];
    vm_address_t source = 0;
    vm_size_t size = 0;
    NSString *image;
    vm_address_t marker = (vm_address_t)function;
    if (!textRange((void *)function, &source, &size, &image)) { row[@"error"] = @"No __TEXT segment"; save(); return; }
    if (!whole) { source = marker & ~((vm_address_t)vm_page_size - 1); size = vm_page_size; }
    row[@"path"] = image; row[@"source"] = hex(source); row[@"size"] = @(size);
    row[@"sourceRegion"] = region(marker); row[@"originalAnswer"] = @(function());
    save();
    if (!executable(row[@"sourceRegion"]) || function() != expected || marker < source || marker - source >= size) return;
    vm_address_t targets[16] = {0};
    BOOL passed = YES;
    for (int i = 0; i < repetitions; i++) {
        NSMutableDictionary *alias = [@{@"index": @(i), @"executed": @NO} mutableCopy];
        [row[@"aliases"] addObject:alias];
        vm_address_t target = 0;
        kern_return_t allocation = KERN_SUCCESS;
        if (fixed) allocation = vm_allocate(mach_task_self(), &target, size, VM_FLAGS_ANYWHERE);
        alias[@"allocation"] = @(allocation);
        if (allocation != KERN_SUCCESS) { passed = NO; save(); break; }
        vm_prot_t current = 0, maximum = 0;
        kern_return_t kr = vm_remap(mach_task_self(), &target, size, 0,
            fixed ? VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE : VM_FLAGS_ANYWHERE,
            mach_task_self(), source, copy, &current, &maximum, VM_INHERIT_SHARE);
        alias[@"result"] = @(kr); alias[@"target"] = hex(target);
        alias[@"returnedCurrent"] = @(current); alias[@"returnedMaximum"] = @(maximum);
        if (kr != KERN_SUCCESS) { if (fixed) vm_deallocate(mach_task_self(), target, size); passed = NO; save(); break; }
        targets[i] = target;
        NSDictionary *actual = region(target + marker - source);
        alias[@"actual"] = actual;
        BOOL equal = memcmp((void *)source, (void *)target, (size_t)size) == 0;
        alias[@"bytesEqual"] = @(equal);
        row[@"stage"] = @"before-execution"; save();
        if (!executable(actual) || !equal) { passed = NO; break; }
        int answer = ((int (*)(void))(target + marker - source))();
        alias[@"answer"] = @(answer); alias[@"executed"] = @YES;
        if (answer != expected) { passed = NO; save(); break; }
        save();
    }
    // Recheck retained aliases after registering all repeated mappings.
    for (int i = 0; i < repetitions; i++) {
        if (!targets[i]) continue;
        if (passed) {
            NSDictionary *actual = region(targets[i] + marker - source);
            if (!executable(actual)) passed = NO;
            else if (((int (*)(void))(targets[i] + marker - source))() != expected) passed = NO;
        }
        vm_deallocate(mach_task_self(), targets[i], size);
    }
    row[@"stage"] = @"complete"; row[@"passed"] = @(passed); save();
}
static void loadLibrary(NSString *name) {
    NSMutableDictionary *row = [@{@"name": name, @"passed": @NO} mutableCopy];
    [report[@"libraries"] addObject:row]; save();
    NSString *file = [documents URLByAppendingPathComponent:name].path;
    void *handle = dlopen(file.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) { const char *error = dlerror(); row[@"error"] = error ? @(error) : @"dlopen failed"; save(); return; }
    int (*ready)(void) = dlsym(handle, "remap_injection_ready");
    int (*answer)(void) = dlsym(handle, "remap_injection_answer");
    row[@"constructor"] = @(ready ? ready() : -1); row[@"answer"] = @(answer ? answer() : -1);
    row[@"actual"] = answer ? region((vm_address_t)answer) : @{};
    row[@"passed"] = @(ready && answer && ready() == 1 && answer() == 73 && executable(row[@"actual"]));
    save(); dlclose(handle);
}
static void standalone(NSString *name) {
    NSString *file = [documents URLByAppendingPathComponent:name].path;
    NSString *output = [documents URLByAppendingPathComponent:[name stringByAppendingString:@".json"]].path;
    NSString *insert = [@"DYLD_INSERT_LIBRARIES=" stringByAppendingString:[documents URLByAppendingPathComponent:@"libinjected-ldid.dylib"].path];
    char *argv[] = {(char *)file.fileSystemRepresentation, (char *)output.fileSystemRepresentation, NULL};
    char *env[] = {(char *)insert.UTF8String, "PATH=/usr/bin:/bin", NULL};
    pid_t pid = 0;
    int error = posix_spawn(&pid, file.fileSystemRepresentation, NULL, NULL, argv, env);
    NSMutableDictionary *row = [@{@"name": name, @"spawnError": @(error), @"pid": @(pid)} mutableCopy];
    [report[@"standalone"] addObject:row]; save();
    if (!error) {
        int status = 0;
        pid_t waited = 0;
        for (int i = 0; i < 100 && waited == 0; i++) { waited = waitpid(pid, &status, WNOHANG); if (!waited) usleep(50000); }
        row[@"waited"] = @(waited);
        if (waited == pid) {
            row[@"exit"] = WIFEXITED(status) ? @(WEXITSTATUS(status)) : NSNull.null;
            row[@"signal"] = WIFSIGNALED(status) ? @(WTERMSIG(status)) : NSNull.null;
        }
    }
    save();
}
static void run(void) {
    size_t length = 256; char release[256] = {0}; sysctlbyname("kern.osrelease", release, &length, NULL, 0);
    Dl_info remap = {0}; dladdr((void *)vm_remap, &remap);
    report = [@{@"pid": @(getpid()), @"kernel": @(release), @"pageSize": @(vm_page_size), @"complete": @NO,
        @"remapSymbolLibrary": remap.dli_fname ? @(remap.dli_fname) : @"unknown", @"cases": [NSMutableArray array],
        @"libraries": [NSMutableArray array], @"standalone": [NSMutableArray array]} mutableCopy];
    save();
    for (int image = 0; image < 2; image++) {
        int (*function)(void) = image ? remap_framework_marker : remap_main_marker;
        NSString *name = image ? @"framework" : @"main";
        int expected = image ? 57 : 42;
        for (int whole = 0; whole < 2; whole++) for (int copy = 0; copy < 2; copy++) for (int fixed = 0; fixed < 2; fixed++)
            remapCase(name, function, expected, whole, copy, fixed, 1);
        for (int copy = 0; copy < 2; copy++) remapCase(name, function, expected, NO, copy, NO, 16);
    }
    loadLibrary(@"libinjected-ldid.dylib"); loadLibrary(@"libinjected-adhoc.dylib");
    standalone(@"standalone-ldid"); standalone(@"standalone-adhoc");
    report[@"complete"] = @YES; save();
}
@interface RemapProbeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation RemapProbeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    self.window.rootViewController = controller; [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ run(); });
}
@end
@interface RemapProbeDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation RemapProbeDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(RemapProbeDelegate.class)); }
}

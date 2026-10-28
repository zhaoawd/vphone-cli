// Standalone ParavirtualizedGraphics probe, outside Virtualization.framework.
// Answers whether PG itself accepts the display topologies the VM service
// refuses. One test per process, because PG checks serial numbers across all
// devices in a process.
//
//   P0  1 device, 1 port,  display port 0 serial S
//   P1  2 devices, 1 port each, both display port 0, same serial S
//   P2  2 devices, 1 port each, both display port 0, serials S and S+1
//   P3  1 device, displayPortCount 2, displays port 0 / port 1, serials S and S+1
//
// Build (PGCreateDeviceWithDescriptor, macOS 15.2+): clang -fobjc-arc -framework Foundation -framework Metal
//        -framework ParavirtualizedGraphics pgprobe.m -o pgprobe
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <ParavirtualizedGraphics/ParavirtualizedGraphics.h>
#import <objc/message.h>
#import <sys/mman.h>

static const uint32_t S = 0x12345678;

// macOS 27 removed the callback memory path; PG now wants a private
// PGMemoryMapDescriptor of guest-physical ranges. There is no guest here, so
// a plain host allocation stands in for guest RAM.
typedef struct { uint64_t physicalAddress; uint64_t length; void *hostAddress; } ProbeGuestRange;

static id memoryMapDescriptor(void) {
    static id map;
    if (map) return map;
    const uint64_t length = 64ull << 20;
    void *host = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    map = [NSClassFromString(@"PGMemoryMapDescriptor") new];
    ((void (*)(id, SEL, ProbeGuestRange))objc_msgSend)(map, NSSelectorFromString(@"addRange:"),
                                                       (ProbeGuestRange){0x80000000ull, length, host});
    return map;
}

static id<PGDevice> makeDevice(id<MTLDevice> mtl, uint32_t ports) {
    PGDeviceDescriptor *desc = [PGDeviceDescriptor new];
    desc.device = mtl;
    desc.mmioLength = 0x4000;
    desc.displayPortCount = ports;
    desc.raiseInterrupt = ^(uint32_t vector) { (void)vector; };
    ((void (*)(id, SEL, id))objc_msgSend)(desc, NSSelectorFromString(@"setMemoryMapDescriptor:"), memoryMapDescriptor());
    ((void (*)(id, SEL, BOOL))objc_msgSend)(desc, NSSelectorFromString(@"setEnableProtectedContent:"), NO);
    id<PGDevice> dev = PGCreateDeviceWithDescriptor(desc);
    printf("  device ports=%u -> %s\n", ports, dev ? "created" : "nil");
    return dev;
}

static id<PGDisplay> makeDisplay(id<PGDevice> dev, NSUInteger port, uint32_t serial, const char *label) {
    PGDisplayDescriptor *d = [PGDisplayDescriptor new];
    d.name = [NSString stringWithFormat:@"probe-%s", label];
    d.sizeInMillimeters = NSMakeSize(70, 100);
    d.queue = dispatch_get_main_queue();
    d.modeChangeHandler = ^(PGDisplayCoord_t size, OSType format) { (void)size; (void)format; };
    d.newFrameEventHandler = ^{};
    id<PGDisplay> disp = [dev newDisplayWithDescriptor:d port:port serialNum:serial];
    if (!disp) {
        printf("  display %s port=%lu serial=0x%x -> nil\n", label, (unsigned long)port, serial);
        return nil;
    }
    PGDisplayMode *mode = [[PGDisplayMode alloc] initWithSizeInPixels:(PGDisplayCoord_t){1398, 2034} refreshRateInHz:60];
    disp.modeList = @[mode];
    printf("  display %s port=%lu serial=0x%x -> created (reports port=%lu serial=0x%x)\n", label,
           (unsigned long)port, serial, (unsigned long)disp.port, disp.serialNum);
    return disp;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        const char *test = argc > 1 ? argv[1] : "P0";
        id<MTLDevice> mtl = MTLCreateSystemDefaultDevice();
        printf("[%s] metal=%s PGMaxDisplayPortCount=%u\n", test, mtl ? mtl.name.UTF8String : "nil", PGMaxDisplayPortCount());
        NSMutableArray *keep = [NSMutableArray array];
        if (!strcmp(test, "P0")) {
            id<PGDevice> a = makeDevice(mtl, 1); if (a) [keep addObject:a];
            id<PGDisplay> x = a ? makeDisplay(a, 0, S, "a0") : nil; if (x) [keep addObject:x];
        } else if (!strcmp(test, "P1") || !strcmp(test, "P2")) {
            uint32_t second = !strcmp(test, "P1") ? S : S + 1;
            id<PGDevice> a = makeDevice(mtl, 1); if (a) [keep addObject:a];
            id<PGDevice> b = makeDevice(mtl, 1); if (b) [keep addObject:b];
            id<PGDisplay> x = a ? makeDisplay(a, 0, S, "a0") : nil; if (x) [keep addObject:x];
            id<PGDisplay> y = b ? makeDisplay(b, 0, second, "b0") : nil; if (y) [keep addObject:y];
        } else if (!strcmp(test, "P3")) {
            id<PGDevice> a = makeDevice(mtl, 2); if (a) [keep addObject:a];
            id<PGDisplay> x = a ? makeDisplay(a, 0, S, "a0") : nil; if (x) [keep addObject:x];
            id<PGDisplay> y = a ? makeDisplay(a, 1, S + 1, "a1") : nil; if (y) [keep addObject:y];
        } else {
            fprintf(stderr, "unknown test %s\n", test);
            return 2;
        }
        // Let hot-plug and any asynchronous validation run before reporting.
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
        printf("[%s] objects alive: %lu\n", test, (unsigned long)keep.count);
    }
    return 0;
}

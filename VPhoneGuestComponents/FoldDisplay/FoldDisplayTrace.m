// Opt-in diagnostics read existing surfaces; they never render a new frame.
#import "FoldDisplayPrivate.h"
#include "FoldDisplaySurfaceSamples.h"

BOOL vpFoldTraceEnabled(void) {
    int fd = open("/var/mobile/Library/Caches/vphone-folddisplay-trace.enabled", O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return NO;
    char enabled = 0;
    ssize_t count = read(fd, &enabled, 1);
    close(fd);
    return count == 1 && enabled == '1';
}

void vpFoldTrace(NSString *event, void *surface, id layer, NSDictionary *fields) {
    if (!vpFoldTraceEnabled()) return;
    @try {
        NSMutableDictionary *row = [fields mutableCopy] ?: [NSMutableDictionary dictionary];
        row[@"event"] = event;
        row[@"pid"] = @(getpid());
        static NSString *bootSession;
        static dispatch_once_t bootOnce;
        dispatch_once(&bootOnce, ^{
            char uuid[64] = {0};
            size_t size = sizeof(uuid);
            if (sysctlbyname("kern.bootsessionuuid", uuid, &size, NULL, 0) == 0)
                bootSession = [NSString stringWithUTF8String:uuid];
        });
        row[@"boot_session_uuid"] = bootSession ?: @"unavailable";
        row[@"guest_uptime_before"] = @(NSProcessInfo.processInfo.systemUptime);
        if (layer) {
            row[@"attached"] = @(vpReadObject(layer, "superlayer") != nil);
            row[@"hidden"] = [layer valueForKey:@"hidden"] ?: NSNull.null;
            row[@"opacity"] = [layer valueForKey:@"opacity"] ?: NSNull.null;
        }
        if (surface) {
            static int (*lock)(void *, uint32_t, uint32_t *), (*unlock)(void *, uint32_t, uint32_t *);
            static void *(*base)(void *);
            static size_t (*width)(void *), (*height)(void *), (*stride)(void *), (*bytes)(void *);
            static uint32_t (*identifier)(void *);
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                void *library = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
                lock = dlsym(library, "IOSurfaceLock"); unlock = dlsym(library, "IOSurfaceUnlock");
                base = dlsym(library, "IOSurfaceGetBaseAddress"); width = dlsym(library, "IOSurfaceGetWidth");
                height = dlsym(library, "IOSurfaceGetHeight"); stride = dlsym(library, "IOSurfaceGetBytesPerRow");
                bytes = dlsym(library, "IOSurfaceGetAllocSize"); identifier = dlsym(library, "IOSurfaceGetID");
            });
            VPhoneFoldSurfaceSamples samples = {0};
            if (lock && unlock && base && width && height && stride && bytes && identifier &&
                lock(surface, 1 /* read-only */, NULL) == 0) {
                samples = vpFoldSampleBGRA(base(surface), width(surface), height(surface), stride(surface), bytes(surface));
                row[@"surface_id"] = @(identifier(surface));
                row[@"width"] = @(width(surface)); row[@"height"] = @(height(surface));
                unlock(surface, 1, NULL);
            }
            row[@"grid_valid"] = @(samples.valid);
            if (samples.valid) {
                row[@"grid_samples"] = @(samples.count);
                row[@"max_rgb"] = @(samples.maxRGB);
                row[@"min_alpha"] = @(samples.minAlpha); row[@"max_alpha"] = @(samples.maxAlpha);
            }
        }
        row[@"guest_uptime_after"] = @(NSProcessInfo.processInfo.systemUptime);
        NSData *json = [NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];
        if (json) vpFoldDisplayLog([@"[DEBUG-f5-hold] " stringByAppendingString:[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]]);
    } @catch (__unused NSException *exception) {
        // A failed diagnostic must not change the fold or release decision.
    }
}

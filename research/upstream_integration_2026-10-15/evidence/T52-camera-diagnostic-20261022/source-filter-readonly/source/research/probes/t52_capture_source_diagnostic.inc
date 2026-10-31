// Read-only CMCapture inspection for the named diagnostic app. No function in
// the inspected image is invoked, and no code or data page is modified.
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <ptrauth.h>

static NSDictionary *T52CaptureSourceDiagnostics(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_LAZY | RTLD_LOCAL);
    void *anchor = handle ? dlsym(handle, "FigCaptureSourceServerStart") : NULL;
    Dl_info info = {0};
    if (!anchor || !dladdr(ptrauth_strip(anchor, ptrauth_key_function_pointer), &info) || !info.dli_fbase)
        return @{@"state": @"image_unavailable"};
    const struct mach_header_64 *header = info.dli_fbase;
    if (header->magic != MH_MAGIC_64) return @{@"state": @"invalid_header"};
    unsigned long size = 0;
    const uint32_t *text = (const uint32_t *)getsectiondata(header, "__TEXT", "__text", &size);
    if (!text || size < 32) return @{@"state": @"text_unavailable"};
    NSMutableArray *matches = [NSMutableArray new];
    // Same structural signature as vcc_find_per_source_filter. This only
    // locates and copies the existing instructions for host-side decoding.
    for (size_t i = 0; i + 5 < size / 4; i++) {
        if (text[i] != 0xAA0003F9u || (text[i + 1] & 0xFFC003FFu) != 0xF94003E2u ||
            text[i + 2] != 0xAA1603E0u || (text[i + 3] & 0xFC000000u) != 0x94000000u ||
            (text[i + 4] & 0xFF00001Fu) != 0x34000000u || (text[i + 5] & 0xFF00001Fu) != 0x34000019u) continue;
        int32_t a = (text[i + 4] >> 5) & 0x7FFFFu, b = (text[i + 5] >> 5) & 0x7FFFFu;
        if (a & 0x40000) a |= (int32_t)0xFFF80000u;
        if (b & 0x40000) b |= (int32_t)0xFFF80000u;
        uintptr_t targetA = (uintptr_t)&text[i + 4] + (intptr_t)a * 4;
        uintptr_t targetB = (uintptr_t)&text[i + 5] + (intptr_t)b * 4;
        if (targetA != targetB) continue;
        size_t first = i > 1024 ? i - 1024 : 0;
        size_t words = MIN((size_t)2048, size / 4 - first);
        NSData *bytes = [NSData dataWithBytes:text + first length:words * 4];
        [matches addObject:@{@"filterPC": [NSString stringWithFormat:@"0x%lx", (unsigned long)&text[i + 4]],
                              @"startPC": [NSString stringWithFormat:@"0x%lx", (unsigned long)(text + first)],
                              @"skipPC": [NSString stringWithFormat:@"0x%lx", (unsigned long)targetA],
                              @"instructionsBase64": [bytes base64EncodedStringWithOptions:0]}];
        if (matches.count >= 8) break;
    }
    NSString *uuid = @"";
    const struct load_command *command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (command->cmd == LC_UUID) {
            uuid = [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)command)->uuid].UUIDString;
            break;
        }
        command = (const struct load_command *)((const char *)command + command->cmdsize);
    }
    return @{@"state": @"captured_readonly", @"image": @(info.dli_fname ?: "?"), @"uuid": uuid,
             @"headerPC": [NSString stringWithFormat:@"0x%lx", (unsigned long)header],
             @"textPC": [NSString stringWithFormat:@"0x%lx", (unsigned long)text], @"textBytes": @(size),
             @"matches": matches};
}

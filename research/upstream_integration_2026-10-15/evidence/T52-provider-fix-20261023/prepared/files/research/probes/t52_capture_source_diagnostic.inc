// Read-only CMCapture inspection for the named diagnostic app. No function in
// the inspected image is invoked, and no code or data page is modified.
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
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
        size_t first = i > 4096 ? i - 4096 : 0;
        size_t words = MIN((size_t)8192, size / 4 - first);
        NSData *bytes = [NSData dataWithBytes:text + first length:words * 4];
        [matches addObject:@{@"filterPC": [NSString stringWithFormat:@"0x%lx", (unsigned long)&text[i + 4]],
                              @"startPC": [NSString stringWithFormat:@"0x%lx", (unsigned long)(text + first)],
                              @"skipPC": [NSString stringWithFormat:@"0x%lx", (unsigned long)targetA],
                              @"instructionsBase64": [bytes base64EncodedStringWithOptions:0]}];
        if (matches.count >= 8) break;
    }
    NSString *uuid = @"";
    intptr_t slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (_dyld_get_image_header(i) == (const struct mach_header *)header)
            slide = _dyld_get_image_vmaddr_slide(i);
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct load_command *command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (command->cmd == LC_UUID) {
            uuid = [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)command)->uuid].UUIDString;
        }
        if (command->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)command;
        if (command->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)command)->segname, "__LINKEDIT") == 0)
            linkedit = (const struct segment_command_64 *)command;
        command = (const struct load_command *)((const char *)command + command->cmdsize);
    }
    NSMutableArray *symbols = [NSMutableArray new];
    if (symtab && linkedit && linkedit->fileoff <= symtab->symoff) {
        uintptr_t base = linkedit->vmaddr + slide - linkedit->fileoff;
        const struct nlist_64 *names = (const struct nlist_64 *)(base + symtab->symoff);
        const char *strings = (const char *)(base + symtab->stroff);
        for (uint32_t i = 0; i < symtab->nsyms && symbols.count < 1000; i++) {
            uint32_t offset = names[i].n_un.n_strx;
            if (offset == 0 || offset >= symtab->strsize) continue;
            const char *name = strings + offset;
            size_t remaining = MIN((size_t)1024, (size_t)symtab->strsize - offset);
            if (strnlen(name, remaining) == remaining) continue;
            if (strstr(name, "CaptureSource") || strstr(name, "Prewarm"))
                [symbols addObject:@{@"name": @(name), @"address": [NSString stringWithFormat:@"0x%lx", (unsigned long)(names[i].n_value + slide)]}];
        }
    }
    NSMutableArray *classes = [NSMutableArray new];
    unsigned int classCount = 0;
    const char **classNames = objc_copyClassNamesForImage(info.dli_fname, &classCount);
    for (unsigned int i = 0; classNames && i < classCount; i++) {
        const char *name = classNames[i];
        if (!strstr(name, "Source") && !strstr(name, "Backing") && !strstr(name, "Provider")) continue;
        Class cls = objc_getClass(name);
        NSMutableArray *methods = [NSMutableArray new];
        for (int meta = 0; meta < 2; meta++) {
            unsigned int count = 0;
            Method *list = class_copyMethodList(meta ? object_getClass(cls) : cls, &count);
            for (unsigned int j = 0; j < count; j++) {
                IMP implementation = method_getImplementation(list[j]);
                [methods addObject:@{@"selector": @(sel_getName(method_getName(list[j]))),
                    @"types": @(method_getTypeEncoding(list[j]) ?: ""), @"classMethod": @(meta != 0),
                    @"implementation": [NSString stringWithFormat:@"%p", ptrauth_strip(implementation, ptrauth_key_function_pointer)]}];
                uintptr_t pc = (uintptr_t)ptrauth_strip(implementation, ptrauth_key_function_pointer);
                if (strcmp(name, "FigCaptureSourceBackingsProvider") == 0 &&
                    pc >= (uintptr_t)text && pc < (uintptr_t)text + size) {
                    NSMutableDictionary *method = [methods.lastObject mutableCopy];
                    size_t bytes = MIN((size_t)4096, (uintptr_t)text + size - pc);
                    method[@"instructionsBase64"] = [[NSData dataWithBytes:(const void *)pc length:bytes] base64EncodedStringWithOptions:0];
                    NSMutableArray *callees = [NSMutableArray new];
                    NSMutableSet *seen = [NSMutableSet new];
                    const uint32_t *instructions = (const uint32_t *)pc;
                    for (size_t k = 0; k < bytes / 4 && callees.count < 64; k++) {
                        uint32_t word = instructions[k];
                        if ((word & 0xfc000000u) != 0x94000000u) continue;
                        int64_t displacement = (int64_t)(word & 0x03ffffffu) << 38;
                        displacement >>= 36;
                        uintptr_t target = pc + k * 4 + displacement;
                        if (target < (uintptr_t)text || target >= (uintptr_t)text + size || [seen containsObject:@(target)]) continue;
                        [seen addObject:@(target)];
                        size_t length = MIN((size_t)1024, (uintptr_t)text + size - target);
                        [callees addObject:@{@"callPC": [NSString stringWithFormat:@"0x%lx", (unsigned long)(pc + k * 4)],
                            @"targetPC": [NSString stringWithFormat:@"0x%lx", (unsigned long)target],
                            @"instructionsBase64": [[NSData dataWithBytes:(const void *)target length:length] base64EncodedStringWithOptions:0]}];
                    }
                    method[@"directCallees"] = callees;
                    methods[methods.count - 1] = method;
                }
            }
            free(list);
        }
        unsigned int propertyCount = 0, ivarCount = 0;
        objc_property_t *propertyList = class_copyPropertyList(cls, &propertyCount);
        Ivar *ivarList = class_copyIvarList(cls, &ivarCount);
        NSMutableArray *properties = [NSMutableArray new], *ivars = [NSMutableArray new];
        for (unsigned int j = 0; j < propertyCount; j++)
            [properties addObject:@{@"name": @(property_getName(propertyList[j])), @"attributes": @(property_getAttributes(propertyList[j]) ?: "")}];
        for (unsigned int j = 0; j < ivarCount; j++)
            [ivars addObject:@{@"name": @(ivar_getName(ivarList[j])), @"type": @(ivar_getTypeEncoding(ivarList[j]) ?: ""), @"offset": @(ivar_getOffset(ivarList[j]))}];
        free(propertyList); free(ivarList);
        [classes addObject:@{@"name": @(name), @"address": [NSString stringWithFormat:@"%p", cls], @"methods": methods,
                             @"properties": properties, @"ivars": ivars}];
    }
    free(classNames);
    // Copy Objective-C dispatch metadata so host-side decoding can name the
    // selectors called by the observed control flow without invoking them.
    unsigned long stubSize = 0;
    const uint8_t *stubs = getsectiondata(header, "__TEXT", "__objc_stubs", &stubSize);
    NSMutableArray *selectorReferences = [NSMutableArray new];
    for (const char **segment = (const char *[]){"__DATA_CONST", "__AUTH_CONST", "__DATA", "__AUTH", NULL}; *segment; segment++) {
        unsigned long referenceSize = 0;
        const SEL *references = (const SEL *)getsectiondata(header, *segment, "__objc_selrefs", &referenceSize);
        if (!references || referenceSize > 1024 * 1024) continue;
        for (size_t i = 0; i < referenceSize / sizeof(SEL); i++) {
            if (!references[i]) continue;
            const char *name = sel_getName(references[i]);
            if (name && strnlen(name, 1024) < 1024)
                [selectorReferences addObject:@{@"slot": [NSString stringWithFormat:@"%p", references + i], @"selector": @(name)}];
        }
    }
    NSDictionary *dispatchMetadata = stubs && stubSize <= 1024 * 1024
        ? @{@"stubPC": [NSString stringWithFormat:@"%p", stubs], @"stubBytes": @(stubSize),
            @"stubBase64": [[NSData dataWithBytes:stubs length:stubSize] base64EncodedStringWithOptions:0],
            @"selectorReferences": selectorReferences} : @{@"state": @"stubs_unavailable", @"selectorReferences": selectorReferences};
    return @{@"state": @"captured_readonly", @"image": @(info.dli_fname ?: "?"), @"uuid": uuid,
             @"headerPC": [NSString stringWithFormat:@"0x%lx", (unsigned long)header],
             @"textPC": [NSString stringWithFormat:@"0x%lx", (unsigned long)text], @"textBytes": @(size),
             @"matches": matches, @"symbols": symbols, @"classes": classes, @"dispatchMetadata": dispatchMetadata};
}

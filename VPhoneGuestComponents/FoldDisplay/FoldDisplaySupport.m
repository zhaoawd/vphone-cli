// The log, the inner display's name, and the KVC and ivar readers every
// section reads backboardd, SpringBoard and FrontBoard objects through.

#import "FoldDisplayPrivate.h"

NSString *const vpInnerDisplayName = @"VPhone Duo Inner";

void vpFoldDisplayLog(NSString *line) {
    int fd = open("/var/mobile/Library/Caches/vphone-folddisplay.log", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
    if (fd < 0)
        return;
    // Seconds since 1970 to the millisecond, so a line can be matched
    // against host-side timings (the guest clock follows the Mac's).
    const char *bytes = [NSString stringWithFormat:@"%.3f %@\n", NSDate.date.timeIntervalSince1970, line].UTF8String;
    if (bytes)
        write(fd, bytes, strlen(bytes));
    close(fd);
}

id vpReadObject(id object, const char *name) {
    SEL selector = sel_registerName(name);
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

id vpReadObjectIvar(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    return type && type[0] == '@' ? object_getIvar(object, ivar) : nil;
}

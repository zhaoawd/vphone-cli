#import "Include/VphonedNative.h"
#include <sys/sysctl.h>
#if __has_include(<libproc.h>)
#include <libproc.h>
#else
extern int proc_pidpath(int, void *, uint32_t);
#define PROC_PIDPATHINFO_MAXSIZE 4096
#endif
#include <string.h>

NSString *vp_backboardd_epoch(void) {
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || !size) return nil;
    size += 64 * sizeof(struct kinfo_proc);
    struct kinfo_proc *processes = calloc(1, size);
    if (!processes) return nil;
    NSString *result = nil;
    if (sysctl(mib, 3, processes, &size, NULL, 0) == 0) {
        for (size_t index = 0; index < size / sizeof(*processes); index++) {
            struct kinfo_proc *process = &processes[index];
            if (process->kp_proc.p_pid <= 1 || strcmp(process->kp_proc.p_comm, "backboardd")) continue;
            char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
            if (proc_pidpath(process->kp_proc.p_pid, path, sizeof(path)) <= 0
                || ![[NSString stringWithUTF8String:path] hasSuffix:@"/backboardd"]) continue;
            if (result) { result = nil; break; }
            result = [NSString stringWithFormat:@"%d:%lld:%lld", process->kp_proc.p_pid,
                (long long)process->kp_proc.p_starttime.tv_sec, (long long)process->kp_proc.p_starttime.tv_usec];
        }
    }
    free(processes);
    return result;
}

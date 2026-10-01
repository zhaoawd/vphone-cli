// macOS harness for vp_process_mapped_files (sources/VPhoneDaemon/Native).
// Usage: harness <dylib> <replacement> <pid-to-inspect-or-0>
// Loads <dylib>, reports the mapping, renames <replacement> over <dylib> the
// way the daemon installs a library, and reports the mapping again. With a
// pid, it also reports whether that process could be inspected.
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "VphonedNative.h"

#ifdef VP_CHECK_LAYOUT
#include <stddef.h>
#include <sys/proc_info.h>
#endif

static VPMappedFile files[8192];

static int find(const char *path, struct stat *current, int *state) {
    int flavor = 0;
    int count = vp_process_mapped_files(getpid(), files, 8192, &flavor);
    if (count < 0) {
        printf("error errno=%d\n", errno);
        return -1;
    }
    *state = 0;
    for (int index = 0; index < count; index++) {
        if (strcmp(files[index].path, path) == 0 || files[index].inode == current->st_ino) {
            *state = files[index].inode == current->st_ino &&
                             files[index].device == (uint32_t)current->st_dev ? 1 : 2;
            printf("mapping path=%s inode=%llu flavor=%d count=%d\n", files[index].path,
                   (unsigned long long)files[index].inode, flavor, count);
        }
    }
    return count;
}

int main(int argc, char **argv) {
    if (argc != 4) return 64;
#ifdef VP_CHECK_LAYOUT
    printf("layout %s\n", vp_proc_info_layout_matches(sizeof(struct proc_regionwithpathinfo),
                                                      offsetof(struct proc_regionwithpathinfo, prp_vip),
                                                      offsetof(struct vnode_info_path, vip_path),
                                                      offsetof(struct vinfo_stat, vst_ino))
                              ? "ok" : "mismatch");
#endif
    char path[1024];
    if (!realpath(argv[1], path)) return 65;
    struct stat original;
    if (stat(path, &original) != 0) return 66;
    int state = 0;
    if (find(path, &original, &state) >= 0) printf("before-load %d\n", state);
    if (!dlopen(path, RTLD_NOW)) {
        printf("dlopen failed %s\n", dlerror());
        return 67;
    }
    if (find(path, &original, &state) >= 0) printf("loaded %s\n", state == 1 ? "current" : state == 2 ? "stale" : "absent");
    if (rename(argv[2], path) != 0) return 68;
    struct stat replaced;
    if (stat(path, &replaced) != 0) return 69;
    printf("inodes old=%llu new=%llu\n", (unsigned long long)original.st_ino, (unsigned long long)replaced.st_ino);
    // The process still maps the old inode; against the new file it is stale.
    int count = vp_process_mapped_files(getpid(), files, 8192, NULL);
    int old = 0, current = 0;
    for (int index = 0; index < count; index++) {
        if (files[index].inode == original.st_ino && files[index].device == (uint32_t)original.st_dev) old = 1;
        if (files[index].inode == replaced.st_ino && files[index].device == (uint32_t)replaced.st_dev) current = 1;
    }
    printf("after-replace old=%d new=%d\n", old, current);
    int pid = atoi(argv[3]);
    if (pid > 0) {
        int flavor = 0;
        int other = vp_process_mapped_files(pid, files, 8192, &flavor);
        printf("pid %d result=%d errno=%d\n", pid, other < 0 ? -1 : other > 0 ? 1 : 0, other < 0 ? errno : 0);
    }
    errno = 0;
    printf("capacity %d errno=%d\n", vp_process_mapped_files(getpid(), files, 1, NULL), errno);
    return 0;
}

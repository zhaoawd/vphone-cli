#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/types.h>

#include "Include/VphonedNative.h"

// MARK: - proc_info layout

// <sys/proc_info.h> is in the macOS SDK but not the iOS SDK. These mirror its
// region-with-path layout; tests/test_daemon_env_mappings.py compares them
// with the macOS header (vp_proc_info_layout_matches).
struct vp_vinfo_stat {
    uint32_t vst_dev;
    uint16_t vst_mode;
    uint16_t vst_nlink;
    uint64_t vst_ino;
    uid_t vst_uid;
    gid_t vst_gid;
    int64_t vst_atime;
    int64_t vst_atimensec;
    int64_t vst_mtime;
    int64_t vst_mtimensec;
    int64_t vst_ctime;
    int64_t vst_ctimensec;
    int64_t vst_birthtime;
    int64_t vst_birthtimensec;
    off_t vst_size;
    int64_t vst_blocks;
    int32_t vst_blksize;
    uint32_t vst_flags;
    uint32_t vst_gen;
    uint32_t vst_rdev;
    int64_t vst_qspare[2];
};

struct vp_vnode_info {
    struct vp_vinfo_stat vi_stat;
    int vi_type;
    int vi_pad;
    fsid_t vi_fsid;
};

struct vp_vnode_info_path {
    struct vp_vnode_info vip_vi;
    char vip_path[MAXPATHLEN];
};

struct vp_proc_regioninfo {
    uint32_t pri_protection;
    uint32_t pri_max_protection;
    uint32_t pri_inheritance;
    uint32_t pri_flags;
    uint64_t pri_offset;
    uint32_t pri_behavior;
    uint32_t pri_user_wired_count;
    uint32_t pri_user_tag;
    uint32_t pri_pages_resident;
    uint32_t pri_pages_shared_now_private;
    uint32_t pri_pages_swapped_out;
    uint32_t pri_pages_dirtied;
    uint32_t pri_ref_count;
    uint32_t pri_shadow_depth;
    uint32_t pri_share_mode;
    uint32_t pri_private_pages_resident;
    uint32_t pri_shared_pages_resident;
    uint32_t pri_obj_id;
    uint32_t pri_depth;
    uint64_t pri_address;
    uint64_t pri_size;
};

struct vp_proc_regionwithpathinfo {
    struct vp_proc_regioninfo prp_prinfo;
    struct vp_vnode_info_path prp_vip;
};

// libproc is not in the iOS SDK; proc_pidinfo is a libsystem_kernel export.
extern int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);

// PROC_PIDREGIONPATHINFO returns the region at or after an address.
// PROC_PIDREGIONPATHINFO2 (private in xnu) skips regions without a vnode.
enum { vp_region_path_info = 8, vp_region_path_info_vnodes = 22 };

bool vp_proc_info_layout_matches(size_t size, size_t vnode_offset, size_t path_offset, size_t inode_offset) {
    return size == sizeof(struct vp_proc_regionwithpathinfo) &&
           vnode_offset == offsetof(struct vp_proc_regionwithpathinfo, prp_vip) &&
           path_offset == offsetof(struct vp_vnode_info_path, vip_path) &&
           inode_offset == offsetof(struct vp_vinfo_stat, vst_ino);
}

// MARK: - Mapped files

static int region(int pid, int flavor, uint64_t address, struct vp_proc_regionwithpathinfo *info) {
    memset(info, 0, sizeof(*info));
    int size = proc_pidinfo(pid, flavor, address, info, (int)sizeof(*info));
    return size == (int)sizeof(*info) ? 0 : (errno ? errno : EINVAL);
}

int vp_process_mapped_files(int pid, VPMappedFile *files, int capacity, int *flavor_used) {
    struct vp_proc_regionwithpathinfo info;
    int flavor = vp_region_path_info_vnodes;
    errno = 0;
    int status = region(pid, flavor, 0, &info);
    if (status == EINVAL) {
        // Kernels without the vnode-only flavor reject it as unknown.
        flavor = vp_region_path_info;
        errno = 0;
        status = region(pid, flavor, 0, &info);
    }
    if (flavor_used) *flavor_used = flavor;
    if (status == EINVAL) return 0;  // no region at all
    if (status != 0) {
        errno = status;
        return -1;
    }
    int count = 0;
    for (int steps = 0; steps < 1 << 22; steps++) {
        const struct vp_vinfo_stat *stat = &info.prp_vip.vip_vi.vi_stat;
        if (stat->vst_ino != 0 || info.prp_vip.vip_path[0] != '\0') {
            bool known = false;
            for (int index = 0; index < count && !known; index++) {
                known = files[index].device == stat->vst_dev && files[index].inode == stat->vst_ino &&
                        strncmp(files[index].path, info.prp_vip.vip_path, sizeof(files[index].path)) == 0;
            }
            if (!known) {
                if (count == capacity) {
                    errno = ENOBUFS;
                    return -1;
                }
                files[count].device = stat->vst_dev;
                files[count].inode = stat->vst_ino;
                strlcpy(files[count].path, info.prp_vip.vip_path, sizeof(files[count].path));
                count++;
            }
        }
        uint64_t next = info.prp_prinfo.pri_address + info.prp_prinfo.pri_size;
        if (info.prp_prinfo.pri_size == 0 || next <= info.prp_prinfo.pri_address) break;
        errno = 0;
        status = region(pid, flavor, next, &info);
        if (status == EINVAL || status == ESRCH) break;  // past the last region, or the process exited
        if (status != 0) {
            errno = status;
            return -1;
        }
    }
    return count;
}

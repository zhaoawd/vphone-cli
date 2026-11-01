/*
 * vphoned_vcam — vsock 1338 -> shared mmap frame publisher.
 *
 * Wire protocol (matches host VPhoneCameraServer.swift):
 *   uint32 LE  total_payload_length
 *   uint32 LE  header_json_length
 *   bytes      JSON header { w, h, bpr, fmt, ts }
 *   bytes      raw pixel data (width*height aligned by bpr)
 *
 * On each successful receive, the frame is written into the shm file
 * with a seq-counter discipline and a notify_post() fires so any
 * libvcamcaptured-mapped reader can pick it up immediately.
 */

#import "vphoned_vcam.h"

#include <errno.h>
#include <fcntl.h>
#include <notify.h>
#include <pthread.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/vsock.h>
#include <unistd.h>
#include <time.h>

static uint64_t s_publisher_started_at_ns;
static uint64_t vvc_mono_ns(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static pthread_once_t s_start_once = PTHREAD_ONCE_INIT;
static uint8_t       *s_shm_base   = NULL;
static int            s_notify_token = -1;
/* Opened once, relative to the camera directory, by open_shm(). Until then
 * log lines go to NSLog. */
static _Atomic int    s_log_fd = -1;

__attribute__((format(printf, 1, 2)))
static void vvc_logf(const char *fmt, ...) {
  char message[1024];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(message, sizeof(message) - 1, fmt, ap);
  va_end(ap);
  int fd = atomic_load(&s_log_fd);
  if (fd < 0) {
    NSLog(@"%s", message);
    return;
  }
  size_t length = strlen(message);
  message[length++] = '\n';
  /* One write per line keeps O_APPEND lines whole across threads. */
  (void)write(fd, message, length);
}

// MARK: - Root-owned files in a mobile-owned directory

static bool is_private_root_file(int fd) {
  struct stat info;
  return fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == 0 &&
         info.st_nlink == 1;
}

/* mobile owns the camera directory, so any entry in it may be a symlink, a
 * hard link to a root-only file, a FIFO, or a file mobile created. Open it
 * relative to the directory without following links, and accept only a
 * regular root-owned file with a single name. Anything else is removed and
 * created again exclusively. O_NONBLOCK keeps a FIFO from blocking the open. */
static int open_root_file(int directory_fd, const char *path, int access) {
  const char *name = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
  int flags = access | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK;
  int fd = openat(directory_fd, name, flags | O_CREAT, 0644);
  if (fd < 0 || !is_private_root_file(fd)) {
    if (fd >= 0) close(fd);
    if (unlinkat(directory_fd, name, 0) < 0 && errno != ENOENT) return -1;
    fd = openat(directory_fd, name, flags | O_CREAT | O_EXCL, 0644);
    if (fd < 0) return -1;
    if (!is_private_root_file(fd)) {
      close(fd);
      errno = EPERM;
      return -1;
    }
  }
  int status = fcntl(fd, F_GETFL);
  if (status < 0 || fcntl(fd, F_SETFL, status & ~O_NONBLOCK) < 0) {
    close(fd);
    return -1;
  }
  return fd;
}

static void open_log(int directory_fd) {
  if (atomic_load(&s_log_fd) >= 0) return;
  int fd = open_root_file(directory_fd, VPHONE_VCAM_DAEMON_LOG_PATH, O_WRONLY | O_APPEND);
  if (fd < 0) {
    vvc_logf("vphoned_vcam: open log failed: %s", strerror(errno));
    return;
  }
  fchmod(fd, 0644);
  int expected = -1;
  if (!atomic_compare_exchange_strong(&s_log_fd, &expected, fd)) close(fd);
}

// MARK: - Shared frame memory

/* Opens the camera directory without following a link in its last two
 * components. /var/mobile belongs to mobile, so Media could be replaced by a
 * symlink; the parent is opened with O_NOFOLLOW and the leaf with openat. */
static int open_camera_directory(uid_t owner, gid_t group) {
  NSString *directory = [NSString stringWithUTF8String:VPHONE_VCAM_DIRECTORY];
  NSString *parent = directory.stringByDeletingLastPathComponent;
  const char *leaf = directory.lastPathComponent.fileSystemRepresentation;
  int parent_fd = open(parent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (parent_fd < 0) {
    vvc_logf("vphoned_vcam: open(%s) failed: %s", parent.UTF8String, strerror(errno));
    return -1;
  }
  if (mkdirat(parent_fd, leaf, 0755) < 0 && errno != EEXIST) {
    vvc_logf("vphoned_vcam: create(%s) failed: %s", directory.UTF8String, strerror(errno));
    close(parent_fd);
    return -1;
  }
  int directory_fd = openat(parent_fd, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  close(parent_fd);
  if (directory_fd < 0) {
    vvc_logf("vphoned_vcam: open directory failed: %s", strerror(errno));
    return -1;
  }
  if (fchown(directory_fd, owner, group) < 0) {
    vvc_logf("vphoned_vcam: chown directory failed: %s", strerror(errno));
    close(directory_fd);
    return -1;
  }
  if (fchmod(directory_fd, 0755) < 0) {
    vvc_logf("vphoned_vcam: chmod directory failed: %s", strerror(errno));
    close(directory_fd);
    return -1;
  }
  return directory_fd;
}

static int open_shm(void) {
  /* Wait for mobile's home before creating its media directory. */
  struct passwd *mobile_user = getpwnam("mobile");
  struct stat mobile_home;
  if (!mobile_user || stat("/var/mobile", &mobile_home) < 0 ||
      !S_ISDIR(mobile_home.st_mode) || mobile_home.st_uid != mobile_user->pw_uid) {
    vvc_logf("vphoned_vcam: mobile home is not ready");
    return -1;
  }
  int directory_fd = open_camera_directory(mobile_user->pw_uid, mobile_user->pw_gid);
  if (directory_fd < 0) return -1;
  open_log(directory_fd);
  /* Truncate to total size each fresh open so a stale half-written file
   * from a previous boot doesn't confuse readers. */
  int fd = open_root_file(directory_fd, VPHONE_VCAM_SHM_PATH, O_RDWR);
  close(directory_fd);
  if (fd < 0) {
    vvc_logf("vphoned_vcam: open(%s) failed: %s",
          VPHONE_VCAM_SHM_PATH,
          strerror(errno));
    return -1;
  }
  if (ftruncate(fd, VPHONE_VCAM_SHM_TOTAL_SIZE) < 0) {
    vvc_logf("vphoned_vcam: ftruncate failed: %s", strerror(errno));
    close(fd);
    return -1;
  }
  /* Make sure other processes can map this file read-only. */
  fchmod(fd, 0644);
  void *base = mmap(
      NULL,
      VPHONE_VCAM_SHM_TOTAL_SIZE,
      PROT_READ | PROT_WRITE,
      MAP_SHARED,
      fd,
      0);
  close(fd);
  if (base == MAP_FAILED) {
    vvc_logf("vphoned_vcam: mmap failed: %s", strerror(errno));
    return -1;
  }
  /* Zero the header on first init so seq starts at 0. */
  memset(base, 0, VPHONE_VCAM_SHM_HEADER_SIZE);
  s_publisher_started_at_ns = vvc_mono_ns();
  s_shm_base = (uint8_t *)base;
  return 0;
}

static ssize_t read_full(int fd, void *buf, size_t n) {
  uint8_t *p = (uint8_t *)buf;
  size_t got = 0;
  while (got < n) {
    ssize_t r = read(fd, p + got, n - got);
    if (r > 0) { got += (size_t)r; continue; }
    if (r == 0) return 0;
    if (errno == EINTR) continue;
    return -1;
  }
  return (ssize_t)got;
}

static void publish_frame(uint32_t w,
                          uint32_t h,
                          uint32_t bpr,
                          uint32_t fmt,
                          uint64_t ts_ns,
                          const char *generation,
                          const uint8_t presentation_id[16],
                          const uint8_t *pixels,
                          size_t pixel_len) {
  if (!s_shm_base) return;
  if (pixel_len > VPHONE_VCAM_SHM_MAX_PIXELS) {
    vvc_logf("vphoned_vcam: frame too large: %zu", pixel_len);
    return;
  }
  vphone_vcam_shm_header_t *hdr = (vphone_vcam_shm_header_t *)s_shm_base;
  uint8_t *dst = s_shm_base + VPHONE_VCAM_SHM_HEADER_SIZE;

  uint64_t prev_seq = atomic_load_explicit(
      (_Atomic uint64_t *)&hdr->seq, memory_order_acquire);
  /* Mark write in progress (odd seq). */
  uint64_t writing_seq = (prev_seq | 1ull) + 2ull;
  atomic_store_explicit(
      (_Atomic uint64_t *)&hdr->seq,
      writing_seq,
      memory_order_release);

  hdr->width = w;
  hdr->height = h;
  hdr->bytes_per_row = bpr;
  hdr->pixel_format = fmt;
  hdr->timestamp_ns = ts_ns;
  hdr->frame_index += 1;
  hdr->published_at_ns = vvc_mono_ns();
  memset(hdr->generation, 0, sizeof(hdr->generation));
  if (generation) strlcpy(hdr->generation, generation, sizeof(hdr->generation));
  memcpy(hdr->presentation_id, presentation_id, 16);
  hdr->pixels_length = (uint32_t)pixel_len;
  memcpy(dst, pixels, pixel_len);

  /* Mark write done (even seq). */
  atomic_store_explicit(
      (_Atomic uint64_t *)&hdr->seq,
      writing_seq + 1ull,
      memory_order_release);

  if (s_notify_token >= 0) {
    notify_post(VPHONE_VCAM_NOTIFY_NAME);
  }
}

static void handle_client(int fd) {
  vvc_logf("vphoned_vcam: client connected fd=%d", fd);
  uint64_t frames = 0;
  for (;;) {
    uint32_t total_len = 0, header_len = 0;
    if (read_full(fd, &total_len, 4) <= 0) break;
    if (read_full(fd, &header_len, 4) <= 0) break;
    if (total_len < 4 || header_len > total_len - 4 ||
        total_len > VPHONE_VCAM_SHM_MAX_PIXELS + 4096) {
      vvc_logf("vphoned_vcam: framing error total=%u header=%u",
            total_len,
            header_len);
      break;
    }
    uint8_t *header_buf = (uint8_t *)malloc(header_len);
    if (!header_buf) break;
    if (read_full(fd, header_buf, header_len) <= 0) {
      free(header_buf);
      break;
    }
    size_t pixel_len = (size_t)total_len - 4 - header_len;
    uint8_t *pixel_buf = (uint8_t *)malloc(pixel_len);
    if (!pixel_buf) { free(header_buf); break; }
    if (read_full(fd, pixel_buf, pixel_len) <= 0) {
      free(header_buf);
      free(pixel_buf);
      break;
    }
    NSData *hd = [NSData dataWithBytesNoCopy:header_buf
                                       length:header_len
                                 freeWhenDone:NO];
    NSError *jerr = nil;
    NSDictionary *hdict = [NSJSONSerialization JSONObjectWithData:hd
                                                          options:0
                                                            error:&jerr];
    uint32_t w   = (uint32_t)[hdict[@"w"]   unsignedIntValue];
    uint32_t h   = (uint32_t)[hdict[@"h"]   unsignedIntValue];
    uint32_t bpr = (uint32_t)[hdict[@"bpr"] unsignedIntValue];
    uint32_t fmt = (uint32_t)[hdict[@"fmt"] unsignedIntValue];
    uint64_t ts  = (uint64_t)[hdict[@"ts"]  unsignedLongLongValue];
    char generation[VPHONE_VCAM_GENERATION_MAX] = {0};
    id value = hdict[@"gen"];
    if ([value isKindOfClass:NSString.class] && [(NSString *)value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] < sizeof(generation))
      strlcpy(generation, [(NSString *)value UTF8String], sizeof(generation));
    uint8_t presentation_id[16] = {0};
    value = hdict[@"presentation_id"];
    if ([value isKindOfClass:NSString.class]) {
      NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value];
      if (uuid) [uuid getUUIDBytes:presentation_id];
    }
    free(header_buf);

    if (!hdict || jerr || w == 0 || h == 0 || bpr == 0 ||
        pixel_len < (size_t)bpr * h) {
      vvc_logf("vphoned_vcam: invalid frame w=%u h=%u bpr=%u pixel_len=%zu jerr=%s",
               w,
               h,
               bpr,
               pixel_len,
               jerr ? jerr.localizedDescription.UTF8String : "(none)");
      free(pixel_buf);
      break;
    }
    publish_frame(w, h, bpr, fmt, ts, generation, presentation_id, pixel_buf, pixel_len);
    free(pixel_buf);

    frames++;
    if ((frames & 29) == 1) {
      vvc_logf("vphoned_vcam: published frame #%llu w=%u h=%u bpr=%u",
            (unsigned long long)frames,
            w,
            h,
            bpr);
    }
  }
  vvc_logf("vphoned_vcam: client disconnected (%llu frames)",
        (unsigned long long)frames);
  close(fd);
}

static void *listener_thread(__unused void *unused) {
  for (;;) {
    int ready;
    @autoreleasepool {
      ready = open_shm();
    }
    if (ready == 0) break;
    sleep(3);
  }

  /* Register the notify name so notify_post() actually delivers. */
  if (notify_register_check(VPHONE_VCAM_NOTIFY_NAME,
                            &s_notify_token) != NOTIFY_STATUS_OK) {
    s_notify_token = -1;
  }

  int srv = socket(AF_VSOCK, SOCK_STREAM, 0);
  if (srv < 0) {
    vvc_logf("vphoned_vcam: socket(AF_VSOCK) failed: %s", strerror(errno));
    return NULL;
  }
  int one = 1;
  setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

  struct sockaddr_vm addr = {
      .svm_len    = sizeof(addr),
      .svm_family = AF_VSOCK,
      .svm_port   = VPHONED_VCAM_VSOCK_PORT,
      .svm_cid    = VMADDR_CID_ANY,
  };
  if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    vvc_logf("vphoned_vcam: bind(%d) failed: %s",
          VPHONED_VCAM_VSOCK_PORT,
          strerror(errno));
    close(srv);
    return NULL;
  }
  if (listen(srv, 2) < 0) {
    vvc_logf("vphoned_vcam: listen failed: %s", strerror(errno));
    close(srv);
    return NULL;
  }
  vvc_logf("vphoned_vcam: listening on vsock %d, shm=%s",
        VPHONED_VCAM_VSOCK_PORT,
        VPHONE_VCAM_SHM_PATH);

  for (;;) {
    int fd = accept(srv, NULL, NULL);
    if (fd < 0) {
      if (errno == EINTR) continue;
      vvc_logf("vphoned_vcam: accept failed: %s", strerror(errno));
      sleep(1);
      continue;
    }
    @autoreleasepool {
      handle_client(fd);
    }
  }
}

static void start_listener_once(void) {
  pthread_t thr;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  int rc = pthread_create(&thr, &attr, listener_thread, NULL);
  pthread_attr_destroy(&attr);
  if (rc != 0) {
    vvc_logf("vphoned_vcam: pthread_create failed: %d", rc);
  }
}

void vp_vcam_start(void) {
  vvc_logf("vphoned_vcam: vp_vcam_start called (pid=%d)", getpid());
  pthread_once(&s_start_once, start_listener_once);
}

// MARK: - vcam_status (guest half of the two-level transport receipt)

/* Read the observe shm with seq-stability discipline. Returns YES if a
 * stable snapshot was captured. The file is created lazily by
 * libvcamcaptured after it observes its first frame, so a missing file is
 * a normal "not observed yet" state, not an error. */
static BOOL read_observe_snapshot(uint64_t *out_index, uint64_t *out_at_ns,
                                  uint64_t *out_count, char *out_gen,
                                  size_t out_gen_cap, uint8_t out_presentation_id[16]) {
  int fd = open(VPHONE_VCAM_OBSERVE_SHM_PATH, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
  if (fd < 0) return NO;
  struct stat st;
  if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode) || st.st_nlink != 1 || st.st_size < VPHONE_VCAM_OBSERVE_SHM_SIZE) {
    close(fd);
    return NO;
  }
  void *base = mmap(NULL, VPHONE_VCAM_OBSERVE_SHM_SIZE, PROT_READ,
                    MAP_SHARED, fd, 0);
  close(fd);
  if (base == MAP_FAILED) return NO;

  BOOL ok = NO;
  const vphone_vcam_observe_header_t *oh =
      (const vphone_vcam_observe_header_t *)base;
  /* Three attempts: read, then re-check seq for a torn/in-progress write. */
  for (int attempt = 0; attempt < 3; attempt++) {
    uint64_t seq_a = atomic_load_explicit(
        (const _Atomic uint64_t *)&oh->seq, memory_order_acquire);
    if (seq_a & 1ull) continue;  /* writer in progress */
    uint64_t idx = oh->observed_frame_index;
    uint64_t at_ns = oh->observed_at_ns;
    uint64_t count = oh->observed_count;
    char gen[VPHONE_VCAM_GENERATION_MAX];
    memcpy(gen, oh->observed_generation, VPHONE_VCAM_GENERATION_MAX);
    gen[VPHONE_VCAM_GENERATION_MAX - 1] = '\0';
    uint8_t presentation_id[16];
    memcpy(presentation_id, oh->presentation_id, 16);
    uint64_t seq_b = atomic_load_explicit(
        (const _Atomic uint64_t *)&oh->seq, memory_order_acquire);
    if (seq_b != seq_a) continue;  /* torn — retry */
    memcpy(out_presentation_id, presentation_id, 16);
    if (out_index) *out_index = idx;
    if (out_at_ns) *out_at_ns = at_ns;
    if (out_count) *out_count = count;
    if (out_gen && out_gen_cap) {
      strncpy(out_gen, gen, out_gen_cap - 1);
      out_gen[out_gen_cap - 1] = '\0';
    }
    ok = YES;
    break;
  }
  munmap(base, VPHONE_VCAM_OBSERVE_SHM_SIZE);
  return ok;
}

NSDictionary *vp_vcam_status(NSDictionary *msg) {
  (void)msg;
  NSMutableDictionary *r = [NSMutableDictionary dictionary];

  if (!s_shm_base) {
    /* No publisher yet: report zeros so the host stays fail-closed. */
    r[@"vphoned_published_frame_index"] = @0;
    r[@"libvcam_observed_frame_index"] = @0;
    r[@"vphoned_published_at_ns"] = @0;
    r[@"libvcam_observed_at_ns"] = @0;
    r[@"generation"] = @"";
    return r;
  }

  const vphone_vcam_shm_header_t *hdr =
      (const vphone_vcam_shm_header_t *)s_shm_base;
  /* Snapshot the publish header with the same seq discipline. */
  uint64_t pub_index = 0, pub_at_ns = 0;
  uint8_t pub_presentation_id[16] = {0};
  char pub_gen[VPHONE_VCAM_GENERATION_MAX];
  pub_gen[0] = '\0';
  for (int attempt = 0; attempt < 3; attempt++) {
    uint64_t seq_a = atomic_load_explicit(
        (const _Atomic uint64_t *)&hdr->seq, memory_order_acquire);
    if (seq_a & 1ull) continue;
    uint64_t candidate_index = hdr->frame_index;
    uint64_t candidate_at_ns = hdr->published_at_ns;
    char candidate_gen[VPHONE_VCAM_GENERATION_MAX];
    memcpy(candidate_gen, hdr->generation, sizeof(candidate_gen));
    candidate_gen[VPHONE_VCAM_GENERATION_MAX - 1] = '\0';
    uint8_t candidate_presentation_id[16];
    memcpy(candidate_presentation_id, hdr->presentation_id, 16);
    uint64_t seq_b = atomic_load_explicit(
        (const _Atomic uint64_t *)&hdr->seq, memory_order_acquire);
    if (seq_b == seq_a) {
      memcpy(pub_presentation_id, candidate_presentation_id, 16);
      pub_index = candidate_index;
      pub_at_ns = candidate_at_ns;
      memcpy(pub_gen, candidate_gen, sizeof(pub_gen));
      break;
    }
  }

  uint64_t obs_index = 0, obs_at_ns = 0, obs_count = 0;
  char obs_gen[VPHONE_VCAM_GENERATION_MAX];
  obs_gen[0] = '\0';
  uint8_t obs_presentation_id[16] = {0};
  BOOL have_obs = read_observe_snapshot(&obs_index, &obs_at_ns, &obs_count,
                                        obs_gen, sizeof(obs_gen), obs_presentation_id);

  /* The receipt proves that at least one frame of this generation was
   * copied from the publish shm, not that the latest frame reached an app.
   * frame_index is local to this publisher process; reject retained observe
   * records from before initialization, even when a generation is reused. */
  uint64_t reported_obs = 0;
  const uint8_t empty_id[16] = {0};
  if (have_obs && memcmp(pub_presentation_id, empty_id, 16) != 0 &&
      memcmp(pub_presentation_id, obs_presentation_id, 16) == 0 && pub_gen[0] && pub_index > 0 &&
      obs_index > 0 && obs_index <= pub_index &&
      s_publisher_started_at_ns > 0 && obs_at_ns >= s_publisher_started_at_ns &&
      strncmp(obs_gen, pub_gen, VPHONE_VCAM_GENERATION_MAX) == 0) {
    reported_obs = obs_index;
  }

  r[@"presentation_id"] = [[NSUUID alloc] initWithUUIDBytes:pub_presentation_id].UUIDString;
  r[@"vphoned_published_frame_index"] = @(pub_index);
  r[@"libvcam_observed_frame_index"] = @(reported_obs);
  r[@"vphoned_published_at_ns"] = @(pub_at_ns);
  r[@"libvcam_observed_at_ns"] = @(reported_obs ? obs_at_ns : 0);
  r[@"libvcam_observed_count"] = @(obs_count);
  r[@"generation"] = [NSString stringWithUTF8String:pub_gen] ?: @"";
  return r;
}

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
#import "vphoned_protocol.h"

#include <errno.h>
#include <fcntl.h>
#include <notify.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

static uint64_t vvc_monotonic_ns(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif
#ifndef VMADDR_CID_ANY
#define VMADDR_CID_ANY 0xFFFFFFFFu
#endif

struct vp_sockaddr_vm {
  __uint8_t  svm_len;
  sa_family_t svm_family;
  __uint16_t svm_reserved1;
  __uint32_t svm_port;
  __uint32_t svm_cid;
};

static pthread_once_t s_start_once = PTHREAD_ONCE_INIT;
static uint8_t       *s_shm_base   = NULL;
static int            s_notify_token = -1;

#define VVC_LOG_PATH "/var/jb/var/mobile/Library/vphone-vcam.log"

__attribute__((format(printf, 1, 2)))
static void vvc_logf(const char *fmt, ...) {
  FILE *fp = fopen(VVC_LOG_PATH, "a");
  if (!fp) return;
  va_list ap;
  va_start(ap, fmt);
  vfprintf(fp, fmt, ap);
  va_end(ap);
  fputc('\n', fp);
  fclose(fp);
}

static int open_shm(void) {
  /* Truncate to total size each fresh open so a stale half-written file
   * from a previous boot doesn't confuse readers. */
  int fd = open(VPHONED_VCAM_SHM_PATH, O_RDWR | O_CREAT, 0644);
  if (fd < 0) {
    vvc_logf("vphoned_vcam: open(%s) failed: %s",
          VPHONED_VCAM_SHM_PATH, strerror(errno));
    return -1;
  }
  if (ftruncate(fd, VPHONED_VCAM_SHM_TOTAL_SIZE) < 0) {
    vvc_logf("vphoned_vcam: ftruncate failed: %s", strerror(errno));
    close(fd);
    return -1;
  }
  /* Make sure other processes can map this file read-only. */
  fchmod(fd, 0644);
  void *base = mmap(NULL, VPHONED_VCAM_SHM_TOTAL_SIZE,
                    PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);
  if (base == MAP_FAILED) {
    vvc_logf("vphoned_vcam: mmap failed: %s", strerror(errno));
    return -1;
  }
  /* Zero the header on first init so seq starts at 0. */
  memset(base, 0, VPHONED_VCAM_SHM_HEADER_SIZE);
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

static void publish_frame(uint32_t w, uint32_t h, uint32_t bpr,
                          uint32_t fmt, uint64_t ts_ns,
                          const char *generation,
                          const uint8_t *pixels, size_t pixel_len) {
  if (!s_shm_base) return;
  if (pixel_len > VPHONED_VCAM_SHM_MAX_PIXELS) {
    vvc_logf("vphoned_vcam: frame too large: %zu", pixel_len);
    return;
  }
  vphoned_vcam_shm_header_t *hdr = (vphoned_vcam_shm_header_t *)s_shm_base;
  uint8_t *dst = s_shm_base + VPHONED_VCAM_SHM_HEADER_SIZE;

  uint64_t prev_seq = atomic_load_explicit(
      (_Atomic uint64_t *)&hdr->seq, memory_order_acquire);
  /* Mark write in progress (odd seq). */
  uint64_t writing_seq = (prev_seq | 1ull) + 2ull;
  atomic_store_explicit((_Atomic uint64_t *)&hdr->seq, writing_seq,
                        memory_order_release);

  hdr->width = w;
  hdr->height = h;
  hdr->bytes_per_row = bpr;
  hdr->pixel_format = fmt;
  hdr->timestamp_ns = ts_ns;
  hdr->frame_index += 1;
  hdr->pixels_length = (uint32_t)pixel_len;
  hdr->published_at_ns = vvc_monotonic_ns();
  /* Copy the generation string NUL-terminated into the fixed field. */
  memset(hdr->generation, 0, VPHONED_VCAM_GENERATION_MAX);
  if (generation && generation[0]) {
    size_t glen = strnlen(generation, VPHONED_VCAM_GENERATION_MAX - 1);
    memcpy(hdr->generation, generation, glen);
  }
  memcpy(dst, pixels, pixel_len);

  /* Mark write done (even seq). */
  atomic_store_explicit((_Atomic uint64_t *)&hdr->seq, writing_seq + 1ull,
                        memory_order_release);

  if (s_notify_token >= 0) {
    notify_post(VPHONED_VCAM_NOTIFY_NAME);
  }
}

static void handle_client(int fd) {
  vvc_logf("vphoned_vcam: client connected fd=%d", fd);
  uint64_t frames = 0;
  for (;;) {
    uint32_t total_len = 0, header_len = 0;
    if (read_full(fd, &total_len, 4) <= 0) break;
    if (read_full(fd, &header_len, 4) <= 0) break;
    if (total_len < 4 || header_len + 4 > total_len ||
        total_len > VPHONED_VCAM_SHM_MAX_PIXELS + 4096) {
      vvc_logf("vphoned_vcam: framing error total=%u header=%u",
            total_len, header_len);
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
    /* Protocol v2: gen binds this frame to a host generation (§8.3). A v1
     * host omits it; we publish an empty generation in that case. */
    char gen_buf[VPHONED_VCAM_GENERATION_MAX];
    gen_buf[0] = '\0';
    id genObj = hdict[@"gen"];
    if ([genObj isKindOfClass:[NSString class]]) {
      const char *g = [(NSString *)genObj UTF8String];
      if (g) {
        strncpy(gen_buf, g, VPHONED_VCAM_GENERATION_MAX - 1);
        gen_buf[VPHONED_VCAM_GENERATION_MAX - 1] = '\0';
      }
    }
    free(header_buf);

    if (!hdict || jerr || w == 0 || h == 0 || bpr == 0 ||
        pixel_len < (size_t)bpr * h) {
      vvc_logf("vphoned_vcam: invalid frame w=%u h=%u bpr=%u pixel_len=%zu jerr=%s",
            w, h, bpr, pixel_len,
            jerr ? jerr.localizedDescription.UTF8String : "(none)");
      free(pixel_buf);
      break;
    }
    publish_frame(w, h, bpr, fmt, ts, gen_buf, pixel_buf, pixel_len);
    free(pixel_buf);

    frames++;
    if ((frames & 29) == 1) {
      vvc_logf("vphoned_vcam: published frame #%llu w=%u h=%u bpr=%u",
            (unsigned long long)frames, w, h, bpr);
    }
  }
  vvc_logf("vphoned_vcam: client disconnected (%llu frames)",
        (unsigned long long)frames);
  close(fd);
}

static void *listener_thread(__unused void *unused) {
  if (open_shm() < 0) return NULL;

  /* Register the notify name so notify_post() actually delivers. */
  if (notify_register_check(VPHONED_VCAM_NOTIFY_NAME,
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

  struct vp_sockaddr_vm addr = {
      .svm_len    = sizeof(addr),
      .svm_family = AF_VSOCK,
      .svm_port   = VPHONED_VCAM_VSOCK_PORT,
      .svm_cid    = VMADDR_CID_ANY,
  };
  if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    vvc_logf("vphoned_vcam: bind(%d) failed: %s",
          VPHONED_VCAM_VSOCK_PORT, strerror(errno));
    close(srv);
    return NULL;
  }
  if (listen(srv, 2) < 0) {
    vvc_logf("vphoned_vcam: listen failed: %s", strerror(errno));
    close(srv);
    return NULL;
  }
  vvc_logf("vphoned_vcam: listening on vsock %d, shm=%s",
        VPHONED_VCAM_VSOCK_PORT, VPHONED_VCAM_SHM_PATH);

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
                                  size_t out_gen_cap) {
  int fd = open(VPHONED_VCAM_OBSERVE_SHM_PATH, O_RDONLY);
  if (fd < 0) return NO;
  void *base = mmap(NULL, VPHONED_VCAM_OBSERVE_SHM_SIZE, PROT_READ,
                    MAP_SHARED, fd, 0);
  close(fd);
  if (base == MAP_FAILED) return NO;

  BOOL ok = NO;
  const vphoned_vcam_observe_header_t *oh =
      (const vphoned_vcam_observe_header_t *)base;
  /* Two attempts: read, then re-check seq for a torn/in-progress write. */
  for (int attempt = 0; attempt < 3; attempt++) {
    uint64_t seq_a = atomic_load_explicit(
        (const _Atomic uint64_t *)&oh->seq, memory_order_acquire);
    if (seq_a & 1ull) continue;  /* writer in progress */
    uint64_t idx = oh->observed_frame_index;
    uint64_t at_ns = oh->observed_at_ns;
    uint64_t count = oh->observed_count;
    char gen[VPHONED_VCAM_GENERATION_MAX];
    memcpy(gen, oh->observed_generation, VPHONED_VCAM_GENERATION_MAX);
    gen[VPHONED_VCAM_GENERATION_MAX - 1] = '\0';
    uint64_t seq_b = atomic_load_explicit(
        (const _Atomic uint64_t *)&oh->seq, memory_order_acquire);
    if (seq_b != seq_a) continue;  /* torn — retry */
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
  munmap(base, VPHONED_VCAM_OBSERVE_SHM_SIZE);
  return ok;
}

NSDictionary *vp_vcam_status(NSDictionary *msg) {
  id reqId = msg[@"id"];
  NSMutableDictionary *r = vp_make_response(@"vcam_status", reqId);

  if (!s_shm_base) {
    /* No publisher yet: report zeros so the host stays fail-closed. */
    r[@"vphoned_published_frame_index"] = @0;
    r[@"libvcam_observed_frame_index"] = @0;
    r[@"vphoned_published_at_ns"] = @0;
    r[@"libvcam_observed_at_ns"] = @0;
    r[@"generation"] = @"";
    return r;
  }

  const vphoned_vcam_shm_header_t *hdr =
      (const vphoned_vcam_shm_header_t *)s_shm_base;
  /* Snapshot the publish header with the same seq discipline. */
  uint64_t pub_index = 0, pub_at_ns = 0;
  char pub_gen[VPHONED_VCAM_GENERATION_MAX];
  pub_gen[0] = '\0';
  for (int attempt = 0; attempt < 3; attempt++) {
    uint64_t seq_a = atomic_load_explicit(
        (const _Atomic uint64_t *)&hdr->seq, memory_order_acquire);
    if (seq_a & 1ull) continue;
    pub_index = hdr->frame_index;
    pub_at_ns = hdr->published_at_ns;
    memcpy(pub_gen, hdr->generation, VPHONED_VCAM_GENERATION_MAX);
    pub_gen[VPHONED_VCAM_GENERATION_MAX - 1] = '\0';
    uint64_t seq_b = atomic_load_explicit(
        (const _Atomic uint64_t *)&hdr->seq, memory_order_acquire);
    if (seq_b == seq_a) break;
  }

  uint64_t obs_index = 0, obs_at_ns = 0, obs_count = 0;
  char obs_gen[VPHONED_VCAM_GENERATION_MAX];
  obs_gen[0] = '\0';
  BOOL have_obs = read_observe_snapshot(&obs_index, &obs_at_ns, &obs_count,
                                        obs_gen, sizeof(obs_gen));

  /* Fail-closed generation binding: the observe index counts only when the
   * consumer's last observed frame belongs to the currently-published
   * generation. A stale observe from a previous generation must not satisfy
   * the receipt. If either side has no generation string (v1 publish), fall
   * back to reporting whatever was observed — the host's own generation
   * match on `generation` still gates the receipt. */
  uint64_t reported_obs = 0;
  if (have_obs) {
    BOOL gen_bound = (pub_gen[0] != '\0');
    if (!gen_bound || strncmp(obs_gen, pub_gen,
                              VPHONED_VCAM_GENERATION_MAX) == 0) {
      reported_obs = obs_index;
    }
  }

  r[@"vphoned_published_frame_index"] = @(pub_index);
  r[@"libvcam_observed_frame_index"] = @(reported_obs);
  r[@"vphoned_published_at_ns"] = @(pub_at_ns);
  r[@"libvcam_observed_at_ns"] = @(reported_obs ? obs_at_ns : 0);
  r[@"libvcam_observed_count"] = @(obs_count);
  r[@"generation"] = [NSString stringWithUTF8String:pub_gen] ?: @"";
  return r;
}

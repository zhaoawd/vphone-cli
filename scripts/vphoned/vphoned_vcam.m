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

_Static_assert(sizeof(vphoned_vcam_shm_header_t) ==
                   VPHONED_VCAM_SHM_HEADER_SIZE,
               "vcam shm header size drift");
_Static_assert(sizeof(vphoned_vcam_observed_t) ==
                   VPHONED_VCAM_OBSERVED_SIZE,
               "vcam observed receipt size drift");

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

static uint64_t monotonic_ns(void) {
  struct timespec ts = {0};
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void copy_bounded(char *dst, size_t capacity, const char *src) {
  if (!dst || capacity == 0) return;
  memset(dst, 0, capacity);
  if (!src) return;
  size_t n = strnlen(src, capacity - 1);
  memcpy(dst, src, n);
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
                          uint32_t protocol_version,
                          const char *generation, const char *role,
                          uint64_t wire_frame_index,
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
  hdr->protocol_version = protocol_version;
  hdr->timestamp_ns = ts_ns;
  hdr->frame_index = wire_frame_index > 0
      ? wire_frame_index : hdr->frame_index + 1;
  hdr->published_at_ns = monotonic_ns();
  hdr->pixels_length = (uint32_t)pixel_len;
  copy_bounded(hdr->generation, sizeof(hdr->generation), generation);
  copy_bounded(hdr->role, sizeof(hdr->role), role);
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
    uint32_t pv  = (uint32_t)[hdict[@"pv"]  unsignedIntValue];
    uint64_t fi  = (uint64_t)[hdict[@"fi"]  unsignedLongLongValue];
    NSString *gen = [hdict[@"gen"] isKindOfClass:[NSString class]]
        ? hdict[@"gen"] : @"";
    NSString *role = [hdict[@"role"] isKindOfClass:[NSString class]]
        ? hdict[@"role"] : @"test";
    free(header_buf);

    if (!hdict || jerr || w == 0 || h == 0 || bpr == 0 ||
        pixel_len < (size_t)bpr * h) {
      vvc_logf("vphoned_vcam: invalid frame w=%u h=%u bpr=%u pixel_len=%zu jerr=%s",
            w, h, bpr, pixel_len,
            jerr ? jerr.localizedDescription.UTF8String : "(none)");
      free(pixel_buf);
      break;
    }
    publish_frame(w, h, bpr, fmt, ts, pv ?: 1,
                  gen.UTF8String, role.UTF8String, fi,
                  pixel_buf, pixel_len);
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

static BOOL snapshot_published(vphoned_vcam_shm_header_t *out) {
  if (!s_shm_base || !out) return NO;
  const vphoned_vcam_shm_header_t *hdr =
      (const vphoned_vcam_shm_header_t *)s_shm_base;
  uint64_t seq_a = atomic_load_explicit(
      (const _Atomic uint64_t *)&hdr->seq, memory_order_acquire);
  if (seq_a == 0 || (seq_a & 1ull)) return NO;
  memcpy(out, hdr, sizeof(*out));
  uint64_t seq_b = atomic_load_explicit(
      (const _Atomic uint64_t *)&hdr->seq, memory_order_acquire);
  return seq_a == seq_b && !(seq_b & 1ull);
}

static BOOL snapshot_observed(vphoned_vcam_observed_t *out) {
  if (!out) return NO;
  int fd = open(VPHONED_VCAM_OBSERVED_PATH, O_RDONLY);
  if (fd < 0) return NO;
  vphoned_vcam_observed_t first = {0}, second = {0};
  ssize_t a = pread(fd, &first, sizeof(first), 0);
  ssize_t b = pread(fd, &second, sizeof(second), 0);
  close(fd);
  if (a != sizeof(first) || b != sizeof(second)) return NO;
  if (first.seq == 0 || (first.seq & 1ull) || first.seq != second.seq) return NO;
  if (memcmp(&first, &second, sizeof(first)) != 0) return NO;
  *out = second;
  return YES;
}

static NSString *bounded_string(const char *bytes, size_t capacity) {
  size_t length = strnlen(bytes, capacity);
  if (length == 0) return @"";
  NSString *value = [[NSString alloc] initWithBytes:bytes
                                             length:length
                                           encoding:NSUTF8StringEncoding];
  return value ?: @"";
}

NSDictionary *vp_vcam_status(NSString *requested_generation) {
  vphoned_vcam_shm_header_t published = {0};
  if (!snapshot_published(&published)) {
    return @{
      @"protocol_version": @VPHONED_VCAM_PROTOCOL_VERSION,
      @"generation": @"",
      @"role": @"",
      @"matches_requested": @NO,
    };
  }

  NSString *generation = bounded_string(
      published.generation, sizeof(published.generation));
  NSString *role = bounded_string(published.role, sizeof(published.role));
  BOOL requested_match = requested_generation.length > 0 &&
      [generation isEqualToString:requested_generation];
  NSMutableDictionary *status = [@{
    @"protocol_version": @(published.protocol_version),
    @"generation": generation,
    @"role": role,
    @"matches_requested": @(requested_match),
    @"vphoned_published_frame_index": @(published.frame_index),
    @"vphoned_published_at_ns": @(published.published_at_ns),
  } mutableCopy];

  vphoned_vcam_observed_t observed = {0};
  if (!requested_match || !snapshot_observed(&observed)) return status;
  NSString *observed_generation = bounded_string(
      observed.generation, sizeof(observed.generation));
  NSString *observed_role = bounded_string(observed.role, sizeof(observed.role));
  BOOL receipt_matches =
      observed.protocol_version == published.protocol_version &&
      observed.protocol_version == VPHONED_VCAM_PROTOCOL_VERSION &&
      observed.frame_index == published.frame_index &&
      [observed_generation isEqualToString:generation] &&
      [observed_role isEqualToString:role] &&
      observed.observed_at_ns >= published.published_at_ns &&
      published.published_at_ns > 0;
  if (receipt_matches) {
    status[@"libvcam_observed_frame_index"] = @(observed.frame_index);
    status[@"libvcam_observed_at_ns"] = @(observed.observed_at_ns);
  }
  return status;
}

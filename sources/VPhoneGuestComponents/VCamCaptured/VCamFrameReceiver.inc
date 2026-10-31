// MARK: - shared-frame reader

#include "../Shared/VPhoneSimulationAccess.h"

// The latest frame copied out of the vphoned-published shm. Mutated only
// from the reader callback thread; readers (AVF stream production, next
// stage) take the lock for the brief duration of a copy.
// (struct vcc_latest_frame_s is forward-declared above as vcc_latest_frame_t
//  for use by the viewfinder injection code.)

vcc_latest_frame_t vcc_latest_frame = {
    .lock = PTHREAD_MUTEX_INITIALIZER,
};

static const uint8_t *vcc_shm_base = NULL;
static uint64_t vcc_last_seq_seen = 0;
static uint64_t vcc_frames_received = 0;
static uint8_t *vcc_staging_pixels = NULL;
static size_t vcc_staging_capacity = 0;

static uint8_t *vcc_observe_base = NULL;
static uint64_t vcc_observe_count = 0;

static uint64_t vcc_monotonic_ns(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

// Lazily create + map the observe shm read-write (we own it). Idempotent.
static void vcc_observe_map(void) {
  if (vcc_observe_base) return;
  vpSimulationConsumeTokens(VP_SIM_OBSERVE_WRITE);
  int fd = open(VPHONE_VCAM_OBSERVE_SHM_PATH, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0644);
  if (fd < 0) {
    vcc_log(@"  observe open(%s) failed: %s", VPHONE_VCAM_OBSERVE_SHM_PATH,
            strerror(errno));
    return;
  }
  struct stat info;
  if (fstat(fd, &info) < 0 || !S_ISREG(info.st_mode) || info.st_nlink != 1 || info.st_uid != geteuid()) {
    close(fd); return;
  }
  if (ftruncate(fd, VPHONE_VCAM_OBSERVE_SHM_SIZE) < 0) {
    vcc_log(@"  observe ftruncate failed: %s", strerror(errno));
    close(fd);
    return;
  }
  fchmod(fd, 0644);
  void *base = mmap(NULL, VPHONE_VCAM_OBSERVE_SHM_SIZE, PROT_READ | PROT_WRITE,
                    MAP_SHARED, fd, 0);
  close(fd);
  if (base == MAP_FAILED) {
    vcc_log(@"  observe mmap failed: %s", strerror(errno));
    return;
  }
  memset(base, 0, VPHONE_VCAM_OBSERVE_SHM_SIZE);
  vcc_observe_base = (uint8_t *)base;
  vcc_log(@"  observe shm mapped %s -> %p", VPHONE_VCAM_OBSERVE_SHM_PATH,
          vcc_observe_base);
}

// Publish an observe record for a frame we just copied out of the frame shm.
// seq even/odd discipline so vphoned reads a stable snapshot.
static void vcc_observe_write(uint64_t frame_index, const char *generation, const uint8_t presentation_id[16]) {
  if (!vcc_observe_base) vcc_observe_map();
  if (!vcc_observe_base) return;
  vphone_vcam_observe_header_t *oh = (vphone_vcam_observe_header_t *)vcc_observe_base;

  uint64_t prev = atomic_load_explicit(
      (_Atomic uint64_t *)&oh->seq, memory_order_acquire);
  uint64_t writing = (prev | 1ull) + 2ull;
  atomic_store_explicit((_Atomic uint64_t *)&oh->seq, writing,
                        memory_order_release);

  memcpy(oh->presentation_id, presentation_id, 16);
  oh->observed_frame_index = frame_index;
  oh->observed_at_ns = vcc_monotonic_ns();
  oh->observed_count = ++vcc_observe_count;
  memset(oh->observed_generation, 0, VPHONE_VCAM_GENERATION_MAX);
  if (generation && generation[0]) {
    size_t glen = strnlen(generation, VPHONE_VCAM_GENERATION_MAX - 1);
    memcpy(oh->observed_generation, generation, glen);
  }

  atomic_store_explicit((_Atomic uint64_t *)&oh->seq, writing + 1ull,
                        memory_order_release);
}

static int vcc_shm_map(void) {
  vpSimulationConsumeTokens(VP_SIM_CAMERA_READ);
  int fd = open(VPHONE_VCAM_SHM_PATH, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) {
    vcc_log(@"  shm open(%s) failed: %s", VPHONE_VCAM_SHM_PATH, strerror(errno));
    return -1;
  }
  struct stat st;
  if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode) || st.st_nlink != 1 || st.st_size < (off_t)VPHONE_VCAM_SHM_TOTAL_SIZE) {
    vcc_log(@"  shm fstat failed or undersized");
    close(fd);
    return -1;
  }
  void *base = mmap(NULL, VPHONE_VCAM_SHM_TOTAL_SIZE, PROT_READ,
                    MAP_SHARED, fd, 0);
  close(fd);
  if (base == MAP_FAILED) {
    vcc_log(@"  shm mmap failed: %s", strerror(errno));
    return -1;
  }
  vcc_shm_base = (const uint8_t *)base;
  vcc_log(@"  shm mapped %s -> %p", VPHONE_VCAM_SHM_PATH, vcc_shm_base);
  return 0;
}

// Read the latest frame with seq-stability discipline. Returns 1 on a
// fresh frame, 0 if seq hasn't advanced since last call or a read tore.
static int vcc_shm_read_latest(void) {
  if (!vcc_shm_base && vcc_shm_map() < 0) return 0;
  const vphone_vcam_shm_header_t *hdr = (const vphone_vcam_shm_header_t *)vcc_shm_base;

  uint64_t seq_a = atomic_load_explicit(
      (const _Atomic uint64_t *)&hdr->seq, memory_order_acquire);
  if (seq_a == vcc_last_seq_seen) return 0;
  if (seq_a & 1ull) return 0;  // writer in progress

  uint32_t w   = hdr->width;
  uint32_t h   = hdr->height;
  uint32_t bpr = hdr->bytes_per_row;
  uint32_t fmt = hdr->pixel_format;
  uint64_t idx = hdr->frame_index;
  uint32_t pix_len = hdr->pixels_length;
  char generation[VPHONE_VCAM_GENERATION_MAX];
  memcpy(generation, hdr->generation, sizeof(generation));
  generation[sizeof(generation) - 1] = '\0';
  uint8_t presentation[16];
  memcpy(presentation, hdr->presentation_id, sizeof(presentation));

  if (pix_len == 0 || pix_len > VPHONE_VCAM_SHM_MAX_PIXELS) return 0;
  if (w == 0 || h == 0 || bpr == 0 || pix_len < (size_t)bpr * h) return 0;

  if (vcc_staging_capacity < pix_len) {
    uint8_t *larger = (uint8_t *)realloc(vcc_staging_pixels, pix_len);
    if (!larger) return 0;
    vcc_staging_pixels = larger;
    vcc_staging_capacity = pix_len;
  }
  memcpy(vcc_staging_pixels, vcc_shm_base + VPHONE_VCAM_SHM_HEADER_SIZE, pix_len);

  // Re-check seq after copy. If it advanced past our snapshot+1 we may
  // have torn — but the writer always sets even seq AFTER pixel write,
  // so seeing the same even seq means our copy was clean.
  uint64_t seq_b = atomic_load_explicit(
      (const _Atomic uint64_t *)&hdr->seq, memory_order_acquire);
  if (seq_b != seq_a) return 0;

  pthread_mutex_lock(&vcc_latest_frame.lock);
  uint8_t *old_pixels = vcc_latest_frame.pixels;
  size_t old_capacity = vcc_latest_frame.pixels_capacity;
  vcc_latest_frame.pixels = vcc_staging_pixels;
  vcc_latest_frame.pixels_capacity = vcc_staging_capacity;
  vcc_latest_frame.pixels_length = pix_len;
  vcc_latest_frame.width = w;
  vcc_latest_frame.height = h;
  vcc_latest_frame.bytes_per_row = bpr;
  vcc_staging_pixels = old_pixels;
  vcc_staging_capacity = old_capacity;
  pthread_mutex_unlock(&vcc_latest_frame.lock);

  vcc_last_seq_seen = seq_a;
  vcc_frames_received++;
  vcc_observe_write(idx, generation, presentation);
  if ((vcc_frames_received & 29) == 1) {
    vcc_log(@"  shm frame #%llu (idx=%llu) w=%u h=%u bpr=%u fmt=0x%08x",
            (unsigned long long)vcc_frames_received,
            (unsigned long long)idx, w, h, bpr, fmt);
  }
  return 1;
}

static void vcc_start_frame_receiver(void) {
  // Subscribe before mapping: cameracaptured may start before vphoned has
  // created the file. The first frame notification retries the map.
  int token = -1;
  dispatch_queue_t q = dispatch_queue_create("com.vphone.vcam.frames", DISPATCH_QUEUE_SERIAL);
  uint32_t status = notify_register_dispatch(
      VPHONE_VCAM_NOTIFY_NAME, &token, q,
      ^(__unused int t) {
        @autoreleasepool {
          (void)vcc_shm_read_latest();
        }
      });
  if (status != NOTIFY_STATUS_OK) {
    vcc_log(@"  notify_register_dispatch(%s) failed: %u",
            VPHONE_VCAM_NOTIFY_NAME, status);
    return;
  }
  vcc_log(@"  subscribed to %s (token=%d)", VPHONE_VCAM_NOTIFY_NAME, token);
  dispatch_async(q, ^{ @autoreleasepool { (void)vcc_shm_read_latest(); } });
}

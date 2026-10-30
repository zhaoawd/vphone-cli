// CSSC execution probe: checks the scalar CSSC results and times each instruction against ADD.
// Native execution costs about one ADD; the guest kernel fallback (kernel-boot-cssc_emulation)
// costs an undefined-instruction exception per execution, i.e. microseconds.
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define ITERATIONS 2000000ULL

static inline uint64_t op_abs(uint64_t x) { uint64_t r; __asm__ volatile(".arch_extension cssc\n abs %0, %1" : "=r"(r) : "r"(x)); return r; }
static inline uint64_t op_cnt(uint64_t x) { uint64_t r; __asm__ volatile(".arch_extension cssc\n cnt %0, %1" : "=r"(r) : "r"(x)); return r; }
static inline uint64_t op_ctz(uint64_t x) { uint64_t r; __asm__ volatile(".arch_extension cssc\n ctz %0, %1" : "=r"(r) : "r"(x)); return r; }
static inline uint64_t op_smax(uint64_t x, uint64_t y) { uint64_t r; __asm__ volatile(".arch_extension cssc\n smax %0, %1, %2" : "=r"(r) : "r"(x), "r"(y)); return r; }
static inline uint64_t op_umin(uint64_t x, uint64_t y) { uint64_t r; __asm__ volatile(".arch_extension cssc\n umin %0, %1, %2" : "=r"(r) : "r"(x), "r"(y)); return r; }
static inline uint64_t op_umin_imm(uint64_t x) { uint64_t r; __asm__ volatile(".arch_extension cssc\n umin %0, %1, #200" : "=r"(r) : "r"(x)); return r; }
static inline uint64_t op_add(uint64_t x) { uint64_t r; __asm__ volatile("add %0, %1, #1" : "=r"(r) : "r"(x)); return r; }

static double ns_per_op(uint64_t (*body)(uint64_t)) {
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  uint64_t v = 0x1234;
  uint64_t start = mach_absolute_time();
  for (uint64_t i = 0; i < ITERATIONS; i++) v = body(v ^ i);
  uint64_t elapsed = mach_absolute_time() - start;
  __asm__ volatile("" : : "r"(v));
  return (double)elapsed * tb.numer / tb.denom / ITERATIONS;
}

static uint64_t loop_add(uint64_t x) { return op_add(x); }
static uint64_t loop_abs(uint64_t x) { return op_abs(x); }
static uint64_t loop_cnt(uint64_t x) { return op_cnt(x); }
static uint64_t loop_ctz(uint64_t x) { return op_ctz(x | 0x8000); }
static uint64_t loop_smax(uint64_t x) { return op_smax(x, 7); }
static uint64_t loop_umin_imm(uint64_t x) { return op_umin_imm(x); }

// Writes a JSON object into out and returns 1 when every result is correct.
int cssc_probe_run(char *out, size_t size) {
  struct { const char *name; uint64_t got, want; } checks[] = {
    {"abs", op_abs((uint64_t)-42), 42},
    {"cnt", op_cnt(0xF0F0F0F0F0F0F0F0ULL), 32},
    {"ctz", op_ctz(0x100), 8},
    {"smax", op_smax((uint64_t)-5, 3), 3},
    {"umin", op_umin((uint64_t)-5, 3), 3},
    {"umin_imm", op_umin_imm(1000), 200},
  };
  int all_ok = 1;
  size_t used = (size_t)snprintf(out, size, "{\"checks\":{");
  for (size_t i = 0; i < sizeof checks / sizeof checks[0]; i++) {
    int ok = checks[i].got == checks[i].want;
    all_ok &= ok;
    used += (size_t)snprintf(out + used, size - used, "%s\"%s\":%s", i ? "," : "", checks[i].name, ok ? "true" : "false");
  }
  double add = ns_per_op(loop_add);
  double abs = ns_per_op(loop_abs), cnt = ns_per_op(loop_cnt), ctz = ns_per_op(loop_ctz);
  double smax = ns_per_op(loop_smax), umin = ns_per_op(loop_umin_imm);
  double worst = abs;
  if (cnt > worst) worst = cnt;
  if (ctz > worst) worst = ctz;
  if (smax > worst) worst = smax;
  if (umin > worst) worst = umin;
  snprintf(out + used, size - used,
           "},\"iterations\":%llu,\"ns_per_op\":{\"add\":%.3f,\"abs\":%.3f,\"cnt\":%.3f,\"ctz\":%.3f,\"smax\":%.3f,\"umin_imm\":%.3f},"
           "\"worst_over_add\":%.2f,\"correct\":%s,\"native\":%s}",
           ITERATIONS, add, abs, cnt, ctz, smax, umin, worst / add, all_ok ? "true" : "false",
           (all_ok && worst < 50.0) ? "true" : "false");
  return all_ok;
}

// Host side of the CSSC probe: prints the same JSON the guest app writes.
#include <stdio.h>

int cssc_probe_run(char *out, unsigned long size);

int main(void) {
  char out[1024];
  int ok = cssc_probe_run(out, sizeof out);
  puts(out);
  return ok ? 0 : 1;
}

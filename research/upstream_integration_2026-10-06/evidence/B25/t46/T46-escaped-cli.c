
#include <unistd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
static volatile sig_atomic_t interrupted = 0;
static void stop(int sig) { interrupted = 1; }
int main(int argc, char **argv) {
  if (argc > 2 && !strcmp(argv[1], "vm") && !strcmp(argv[2], "list")) { puts("[]"); return 0; }
  if (argc > 1 && !strcmp(argv[1], "doctor")) {
    const char *root = "/private/tmp/vphone-b25-t46/ui-escaped";
    if (!root) return 90;
    const char *mode = "escaped";
    int escaped = mode && !strcmp(mode, "escaped");
    if (escaped && fork() != 0) return 0;
    if (escaped) { if (setsid() < 0) return 91; signal(SIGINT, SIG_IGN); }
    else signal(SIGINT, stop);
    for (int i = 0; i < 10000; i++) printf("\033[32mordinary:%d\033[0m\r\n", i);
    printf("ordinary ready\n"); fflush(stdout);
    char ready[4096], release[4096];
    snprintf(ready, sizeof(ready), "%s/ready", root);
    snprintf(release, sizeof(release), "%s/release", root);
    FILE *f = fopen(ready, "w");
    if (!f) return 92;
    fprintf(f, "pid=%d pgid=%d sid=%d escaped=%d\n", getpid(), getpgrp(), getsid(0), escaped); fclose(f);
    for (int i = 0; i < 12000 && !interrupted && access(release, F_OK) != 0; i++) usleep(10000);
    printf("\033[31mkernel panic: ordinary final tail\033[0m"); fflush(stdout);
    return escaped ? 0 : 130;
  }
  if (argc > 2 && !strcmp(argv[1], "helper") && !strcmp(argv[2], "status")) { puts("controlled fixture: no helper contacted"); return 1; }
  puts("controlled fixture: unsupported command"); return 2;
}

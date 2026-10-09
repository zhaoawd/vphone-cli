#!/usr/bin/env python3
"""Copy a built signed Launchpad app and embed a signed controlled CLI.
Only prepares an isolated fixture; never launches UI, VM or system services.
"""
import json, pathlib, re, shutil, subprocess, sys
source, destination = map(pathlib.Path, sys.argv[1:3])
if not source.is_dir() or destination.exists() or not str(destination.resolve()).startswith('/private/tmp/'):
    raise SystemExit('Require source app and absent destination under /private/tmp/')
shutil.copytree(source, destination)
cli = destination / 'Contents/Helpers/vphone-cli.app/Contents/MacOS/vphone-cli'
helper = destination / 'Contents/Helpers/vphone-cli.app'
c_source = destination.parent / (destination.stem + '-cli.c')
c_source.write_text(r'''
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
    const char *root = getenv("T46_UI_EVIDENCE");
    if (!root) return 90;
    const char *mode = getenv("T46_UI_MODE");
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
    for (int i = 0; i < 3000 && !interrupted && access(release, F_OK) != 0; i++) usleep(10000);
    printf("\033[31mkernel panic: ordinary final tail\033[0m"); fflush(stdout);
    return escaped ? 0 : 130;
  }
  if (argc > 2 && !strcmp(argv[1], "helper") && !strcmp(argv[2], "status")) { puts("controlled fixture: no helper contacted"); return 1; }
  puts("controlled fixture: unsupported command"); return 2;
}
''')
subprocess.run(['/usr/bin/clang', str(c_source), '-o', str(cli)], check=True)
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'com.vphone.cli', str(cli)], check=True)
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(helper)], check=True)
def cdhash(path):
    result = subprocess.run(['/usr/bin/codesign', '-dvvv', str(path)], text=True, capture_output=True, check=True)
    return re.search(r'^CDHash=(\S+)', result.stderr, re.M).group(1)
manifest_path = destination / 'Contents/Resources/embedded-toolchain.json'
manifest = json.loads(manifest_path.read_text())
manifest['vphoneCLI']['cdhash'] = cdhash(cli)
manifest['gitHash'] += '-controlled-T46-CLI'
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'com.vphone.cli.launchpad', str(destination)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
print(destination)

#!/bin/sh
set -eu
PATH=/var/root/vphone-b29-control/bin
export PATH
base=/var/root/vphone-b29-control
root=/private/var/containers/Bundle/Application/.jbroot-000114514191980C
test "$(cat "$base/dry-run.status")" = 0
actual=$(sha256sum "$root/Library/dpkg/status")
case "$actual" in 9b2921483f511b548761d5807f532e69e63ac90b515acfbc2497810a40eb8fc5*) ;; *) echo B29_STATE_CHANGED; exit 1;; esac
set +e
env -u DYLD_LIBRARY_PATH "$root/usr/libexec/irisin-install" < /var/root/vphone-b29/job.install.json > "$base/install.jsonl" 2>&1
status=$?
echo "$status" > "$base/install.status"
tail -20 "$base/install.jsonl"
echo B29_INSTALL_STATUS:$status

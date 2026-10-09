#!/bin/sh
set -eu
PATH=/var/root/vphone-b29-control/bin
export PATH
umask 077
base=/var/root/vphone-b29-control
test ! -e /var/root/vphone-b29/job.dry-run.json
cat "$base"/raw-part-* > "$base/bundle.tar"
actual=$(sha256sum "$base/bundle.tar")
case "$actual" in 206978e0d71296844de31d8641bd59959cd9538dc6deb65f12dbea7c57269924*) ;; *) echo B29_ARCHIVE_DIGEST_FAILED; exit 1;; esac
mkdir -p /var/root/vphone-b29
tar -xf "$base/bundle.tar" -C /var/root/vphone-b29
echo B29_UNPACK_OK
root=/private/var/containers/Bundle/Application/.jbroot-000114514191980C
set +e
env -u DYLD_LIBRARY_PATH "$root/usr/libexec/irisin-install" < /var/root/vphone-b29/job.dry-run.json > "$base/dry-run.jsonl" 2>&1
status=$?
echo "$status" > "$base/dry-run.status"
tail -8 "$base/dry-run.jsonl"
echo B29_DRY_RUN_STATUS:$status

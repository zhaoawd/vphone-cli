#!/iosbinpack64/bin/bash
set -eu
PATH=/var/root/vphone-b33-control/bin
export PATH
unset DYLD_LIBRARY_PATH
base=/var/root/vphone-b33-control
cat "$base"/packages.part?? > "$base/packages.tar.gz"
mkdir -p /var/root/vphone-b34-packages
tar -xzf "$base/packages.tar.gz" -C /var/root/vphone-b34-packages
echo B34_UNPACK_OK
set +e
"/private/var/containers/Bundle/Application/.jbroot-000114514191980C/usr/libexec/irisin-install" < /var/root/vphone-b34-packages/job.dry-run.json > "$base/dry-run.jsonl" 2>&1
status=$?
echo "$status" > "$base/dry-run.status"
tail -8 "$base/dry-run.jsonl"
echo B34_DRY_RUN_STATUS:$status
exit "$status"

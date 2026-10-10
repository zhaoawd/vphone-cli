#!/iosbinpack64/bin/bash
set -eu
PATH=/var/root/vphone-b33-control/bin
export PATH
unset DYLD_LIBRARY_PATH
test "$(cat /var/root/vphone-b33-control/dry-run.status)" = 0
set +e
"/private/var/containers/Bundle/Application/.jbroot-000114514191980C/usr/libexec/irisin-install" < /var/root/vphone-b34-packages/job.install.json > /var/root/vphone-b33-control/install.jsonl 2>&1
status=$?
echo "$status" > /var/root/vphone-b33-control/install.status
tail -20 /var/root/vphone-b33-control/install.jsonl
echo B34_INSTALL_STATUS:$status
exit "$status"

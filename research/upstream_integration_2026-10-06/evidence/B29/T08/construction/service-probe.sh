#!/bin/sh
set -u
PATH=/var/root/vphone-b29-control/bin
export PATH
root=/private/var/containers/Bundle/Application/.jbroot-000114514191980C
for target in system/wiki.qaq.irisind user/0/wiki.qaq.irisind user/501/wiki.qaq.irisind gui/501/wiki.qaq.irisind; do
 echo DOMAIN:$target
 env -u DYLD_LIBRARY_PATH PATH=/usr/bin:/bin:/usr/sbin:/sbin "$root/bin/sh" -c 'launchctl print "$1"' probe "$target"
 echo STATUS:$?
done
env -u DYLD_LIBRARY_PATH PATH=/usr/bin:/bin:/usr/sbin:/sbin "$root/bin/sh" -c 'ps -A -o pid,ppid,stat,comm | grep -E "irisind|vphoned|sshd"; launchctl print system/com.openssh.sshd | head -45'
echo B29_SERVICE_PROBE_END

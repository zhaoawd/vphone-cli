#!/bin/sh
set -u
root=/private/var/containers/Bundle/Application/.jbroot-000114514191980C
echo '{"bootstrapIrisinDaemon":{}}' | "$root/usr/libexec/irisin-install"
irisin_status=$?
"$root/bin/sh" -c 'PATH=/usr/bin:/bin:/usr/sbin:/sbin; launchctl bootstrap system /Library/LaunchDaemons/com.openssh.sshd.plist'
ssh_status=$?
echo B34_ACTIVATION_IRISIN:$irisin_status
echo B34_ACTIVATION_SSH:$ssh_status
test "$irisin_status" = 0 && test "$ssh_status" = 0

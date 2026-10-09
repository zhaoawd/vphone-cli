#!/bin/sh
set -eu
PATH=/var/root/vphone-b29-control/bin
export PATH
root=/private/var/containers/Bundle/Application/.jbroot-000114514191980C
umask 077
test -d "$root/usr/lib"
for item in tmp var etc var/root; do
 if [ ! -e "$root/$item" ]; then
  mkdir -p "$root/$item"
  case "$item" in tmp) chmod 1777 "$root/$item";; var/root) chmod 700 "$root/$item";; *) chmod 755 "$root/$item";; esac
  chown 0:0 "$root/$item"
 fi
done
test -e "$root/var/tmp" || ln -s ../tmp "$root/var/tmp"
test -e "$root/dev" || ln -s /dev "$root/dev"
test -e "$root/rootfs" || ln -s / "$root/rootfs"
for item in passwd group master.passwd; do
 if [ ! -e "$root/etc/$item" ]; then
  cp -p "/private/etc/$item" "$root/etc/$item"
  case "$item" in master.passwd) chmod 600 "$root/etc/$item";; *) chmod 644 "$root/etc/$item";; esac
  chown 0:0 "$root/etc/$item"
 fi
done
ls -ld "$root/tmp" "$root/var/root" "$root/var/tmp" "$root/dev" "$root/rootfs"
stat -c '%n %a %u:%g' "$root/etc/passwd" "$root/etc/group" "$root/etc/master.passwd"
echo B29_BASE_OK
set +e
env -u DYLD_LIBRARY_PATH "$root/usr/libexec/irisin-install" </dev/null
status=$?
echo B29_HELPER_EMPTY_STATUS:$status

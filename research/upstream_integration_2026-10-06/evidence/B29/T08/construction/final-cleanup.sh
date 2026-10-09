#!/bin/sh
set -eu
PATH=/var/root/vphone-b29-control/bin
export PATH
root=/private/var/containers/Bundle/Application/.jbroot-000114514191980C
base=/var/root/vphone-b29-control
test -d "$root" && test ! -L "$root"
env -u DYLD_LIBRARY_PATH PATH=/usr/bin:/bin:/usr/sbin:/sbin "$root/bin/sh" -c 'set -eu; test "$(dpkg-query -W -f="\${Status}\n" | grep -c "^install ok installed$")" = 90; dpkg --audit'
sha256sum "$root/Library/dpkg/status" /usr/bin/vphoned /var/root/Library/Caches/vphoned > "$base/final-before.sha256"
for path in /var/root/vphone-b29 "$base/bundle.tar" "$base/bundle.tar.gz" "$base"/part-00[0-6] "$base"/raw-part-00[0-9] "$base"/raw-part-01[0-3]; do
 test ! -L "$path"
 if [ -e "$path" ]; then du -sk "$path"; rm -rf -- "$path"; fi
 test ! -e "$path"
done
sha256sum -c "$base/final-before.sha256"
env -u DYLD_LIBRARY_PATH PATH=/usr/bin:/bin:/usr/sbin:/sbin "$root/bin/sh" -c 'set -eu; id root; id mobile; test -c /dev/null; : >/dev/null; dpkg --audit; apt --version; curl --version | head -1'
echo B29_FINAL_CLEANUP_OK

#!/bin/sh
set -eu
PATH=/var/root/vphone-b29-control/bin
export PATH
root=/private/var/containers/Bundle/Application/.jbroot-000114514191980C
if [ -d "$root/Applications/Fila.app" ]; then
 if [ ! -e "$root/Applications/Fila.app/.jbroot" ] && [ ! -L "$root/Applications/Fila.app/.jbroot" ]; then ln -s ../../.jbroot "$root/Applications/Fila.app/.jbroot"; echo "created-link:Applications/Fila.app"; fi
 test "$(readlink -f "$root/Applications/Fila.app/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/Fila.app/Frameworks" ]; then
 if [ ! -e "$root/Applications/Fila.app/Frameworks/.jbroot" ] && [ ! -L "$root/Applications/Fila.app/Frameworks/.jbroot" ]; then ln -s ../../../.jbroot "$root/Applications/Fila.app/Frameworks/.jbroot"; echo "created-link:Applications/Fila.app/Frameworks"; fi
 test "$(readlink -f "$root/Applications/Fila.app/Frameworks/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/Fila.app/Frameworks/FilaApplications.framework" ]; then
 if [ ! -e "$root/Applications/Fila.app/Frameworks/FilaApplications.framework/.jbroot" ] && [ ! -L "$root/Applications/Fila.app/Frameworks/FilaApplications.framework/.jbroot" ]; then ln -s ../../../../.jbroot "$root/Applications/Fila.app/Frameworks/FilaApplications.framework/.jbroot"; echo "created-link:Applications/Fila.app/Frameworks/FilaApplications.framework"; fi
 test "$(readlink -f "$root/Applications/Fila.app/Frameworks/FilaApplications.framework/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/Fila.app/Frameworks/FilaCore.framework" ]; then
 if [ ! -e "$root/Applications/Fila.app/Frameworks/FilaCore.framework/.jbroot" ] && [ ! -L "$root/Applications/Fila.app/Frameworks/FilaCore.framework/.jbroot" ]; then ln -s ../../../../.jbroot "$root/Applications/Fila.app/Frameworks/FilaCore.framework/.jbroot"; echo "created-link:Applications/Fila.app/Frameworks/FilaCore.framework"; fi
 test "$(readlink -f "$root/Applications/Fila.app/Frameworks/FilaCore.framework/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/Fila.app/Frameworks/FilaLocal.framework" ]; then
 if [ ! -e "$root/Applications/Fila.app/Frameworks/FilaLocal.framework/.jbroot" ] && [ ! -L "$root/Applications/Fila.app/Frameworks/FilaLocal.framework/.jbroot" ]; then ln -s ../../../../.jbroot "$root/Applications/Fila.app/Frameworks/FilaLocal.framework/.jbroot"; echo "created-link:Applications/Fila.app/Frameworks/FilaLocal.framework"; fi
 test "$(readlink -f "$root/Applications/Fila.app/Frameworks/FilaLocal.framework/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/Fila.app/Frameworks/FilaMusicLibrary.framework" ]; then
 if [ ! -e "$root/Applications/Fila.app/Frameworks/FilaMusicLibrary.framework/.jbroot" ] && [ ! -L "$root/Applications/Fila.app/Frameworks/FilaMusicLibrary.framework/.jbroot" ]; then ln -s ../../../../.jbroot "$root/Applications/Fila.app/Frameworks/FilaMusicLibrary.framework/.jbroot"; echo "created-link:Applications/Fila.app/Frameworks/FilaMusicLibrary.framework"; fi
 test "$(readlink -f "$root/Applications/Fila.app/Frameworks/FilaMusicLibrary.framework/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/Fila.app/Frameworks/FilaPrivileged.framework" ]; then
 if [ ! -e "$root/Applications/Fila.app/Frameworks/FilaPrivileged.framework/.jbroot" ] && [ ! -L "$root/Applications/Fila.app/Frameworks/FilaPrivileged.framework/.jbroot" ]; then ln -s ../../../../.jbroot "$root/Applications/Fila.app/Frameworks/FilaPrivileged.framework/.jbroot"; echo "created-link:Applications/Fila.app/Frameworks/FilaPrivileged.framework"; fi
 test "$(readlink -f "$root/Applications/Fila.app/Frameworks/FilaPrivileged.framework/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/Fila.app/Frameworks/FilaSMB.framework" ]; then
 if [ ! -e "$root/Applications/Fila.app/Frameworks/FilaSMB.framework/.jbroot" ] && [ ! -L "$root/Applications/Fila.app/Frameworks/FilaSMB.framework/.jbroot" ]; then ln -s ../../../../.jbroot "$root/Applications/Fila.app/Frameworks/FilaSMB.framework/.jbroot"; echo "created-link:Applications/Fila.app/Frameworks/FilaSMB.framework"; fi
 test "$(readlink -f "$root/Applications/Fila.app/Frameworks/FilaSMB.framework/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/Fila.app/Frameworks/Runestone.framework" ]; then
 if [ ! -e "$root/Applications/Fila.app/Frameworks/Runestone.framework/.jbroot" ] && [ ! -L "$root/Applications/Fila.app/Frameworks/Runestone.framework/.jbroot" ]; then ln -s ../../../../.jbroot "$root/Applications/Fila.app/Frameworks/Runestone.framework/.jbroot"; echo "created-link:Applications/Fila.app/Frameworks/Runestone.framework"; fi
 test "$(readlink -f "$root/Applications/Fila.app/Frameworks/Runestone.framework/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/Fila.app/PlugIns/FilaSaveAction.appex" ]; then
 if [ ! -e "$root/Applications/Fila.app/PlugIns/FilaSaveAction.appex/.jbroot" ] && [ ! -L "$root/Applications/Fila.app/PlugIns/FilaSaveAction.appex/.jbroot" ]; then ln -s ../../../../.jbroot "$root/Applications/Fila.app/PlugIns/FilaSaveAction.appex/.jbroot"; echo "created-link:Applications/Fila.app/PlugIns/FilaSaveAction.appex"; fi
 test "$(readlink -f "$root/Applications/Fila.app/PlugIns/FilaSaveAction.appex/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/Inspector.app" ]; then
 if [ ! -e "$root/Applications/Inspector.app/.jbroot" ] && [ ! -L "$root/Applications/Inspector.app/.jbroot" ]; then ln -s ../../.jbroot "$root/Applications/Inspector.app/.jbroot"; echo "created-link:Applications/Inspector.app"; fi
 test "$(readlink -f "$root/Applications/Inspector.app/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/Inspector.app/Frameworks" ]; then
 if [ ! -e "$root/Applications/Inspector.app/Frameworks/.jbroot" ] && [ ! -L "$root/Applications/Inspector.app/Frameworks/.jbroot" ]; then ln -s ../../../.jbroot "$root/Applications/Inspector.app/Frameworks/.jbroot"; echo "created-link:Applications/Inspector.app/Frameworks"; fi
 test "$(readlink -f "$root/Applications/Inspector.app/Frameworks/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/Xrash.app" ]; then
 if [ ! -e "$root/Applications/Xrash.app/.jbroot" ] && [ ! -L "$root/Applications/Xrash.app/.jbroot" ]; then ln -s ../../.jbroot "$root/Applications/Xrash.app/.jbroot"; echo "created-link:Applications/Xrash.app"; fi
 test "$(readlink -f "$root/Applications/Xrash.app/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/Xrash.app/Frameworks/libarchive.framework" ]; then
 if [ ! -e "$root/Applications/Xrash.app/Frameworks/libarchive.framework/.jbroot" ] && [ ! -L "$root/Applications/Xrash.app/Frameworks/libarchive.framework/.jbroot" ]; then ln -s ../../../../.jbroot "$root/Applications/Xrash.app/Frameworks/libarchive.framework/.jbroot"; echo "created-link:Applications/Xrash.app/Frameworks/libarchive.framework"; fi
 test "$(readlink -f "$root/Applications/Xrash.app/Frameworks/libarchive.framework/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/iGhostVT.app" ]; then
 if [ ! -e "$root/Applications/iGhostVT.app/.jbroot" ] && [ ! -L "$root/Applications/iGhostVT.app/.jbroot" ]; then ln -s ../../.jbroot "$root/Applications/iGhostVT.app/.jbroot"; echo "created-link:Applications/iGhostVT.app"; fi
 test "$(readlink -f "$root/Applications/iGhostVT.app/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/iGhostVT.app/PlugIns/iGhostVTWidgets.appex" ]; then
 if [ ! -e "$root/Applications/iGhostVT.app/PlugIns/iGhostVTWidgets.appex/.jbroot" ] && [ ! -L "$root/Applications/iGhostVT.app/PlugIns/iGhostVTWidgets.appex/.jbroot" ]; then ln -s ../../../../.jbroot "$root/Applications/iGhostVT.app/PlugIns/iGhostVTWidgets.appex/.jbroot"; echo "created-link:Applications/iGhostVT.app/PlugIns/iGhostVTWidgets.appex"; fi
 test "$(readlink -f "$root/Applications/iGhostVT.app/PlugIns/iGhostVTWidgets.appex/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/irisin.app" ]; then
 if [ ! -e "$root/Applications/irisin.app/.jbroot" ] && [ ! -L "$root/Applications/irisin.app/.jbroot" ]; then ln -s ../../.jbroot "$root/Applications/irisin.app/.jbroot"; echo "created-link:Applications/irisin.app"; fi
 test "$(readlink -f "$root/Applications/irisin.app/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/irisin.app/Frameworks" ]; then
 if [ ! -e "$root/Applications/irisin.app/Frameworks/.jbroot" ] && [ ! -L "$root/Applications/irisin.app/Frameworks/.jbroot" ]; then ln -s ../../../.jbroot "$root/Applications/irisin.app/Frameworks/.jbroot"; echo "created-link:Applications/irisin.app/Frameworks"; fi
 test "$(readlink -f "$root/Applications/irisin.app/Frameworks/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/irisin.app/Frameworks/CLibSolv.framework" ]; then
 if [ ! -e "$root/Applications/irisin.app/Frameworks/CLibSolv.framework/.jbroot" ] && [ ! -L "$root/Applications/irisin.app/Frameworks/CLibSolv.framework/.jbroot" ]; then ln -s ../../../../.jbroot "$root/Applications/irisin.app/Frameworks/CLibSolv.framework/.jbroot"; echo "created-link:Applications/irisin.app/Frameworks/CLibSolv.framework"; fi
 test "$(readlink -f "$root/Applications/irisin.app/Frameworks/CLibSolv.framework/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/irisin.app/Frameworks/WCDBSwift.framework" ]; then
 if [ ! -e "$root/Applications/irisin.app/Frameworks/WCDBSwift.framework/.jbroot" ] && [ ! -L "$root/Applications/irisin.app/Frameworks/WCDBSwift.framework/.jbroot" ]; then ln -s ../../../../.jbroot "$root/Applications/irisin.app/Frameworks/WCDBSwift.framework/.jbroot"; echo "created-link:Applications/irisin.app/Frameworks/WCDBSwift.framework"; fi
 test "$(readlink -f "$root/Applications/irisin.app/Frameworks/WCDBSwift.framework/.jbroot")" = "$root"
fi
if [ -d "$root/Applications/irisin.app/Frameworks/libarchive.framework" ]; then
 if [ ! -e "$root/Applications/irisin.app/Frameworks/libarchive.framework/.jbroot" ] && [ ! -L "$root/Applications/irisin.app/Frameworks/libarchive.framework/.jbroot" ]; then ln -s ../../../../.jbroot "$root/Applications/irisin.app/Frameworks/libarchive.framework/.jbroot"; echo "created-link:Applications/irisin.app/Frameworks/libarchive.framework"; fi
 test "$(readlink -f "$root/Applications/irisin.app/Frameworks/libarchive.framework/.jbroot")" = "$root"
fi
if [ -d "$root/bin" ]; then
 if [ ! -e "$root/bin/.jbroot" ] && [ ! -L "$root/bin/.jbroot" ]; then ln -s ../.jbroot "$root/bin/.jbroot"; echo "created-link:bin"; fi
 test "$(readlink -f "$root/bin/.jbroot")" = "$root"
fi
if [ -d "$root/sbin" ]; then
 if [ ! -e "$root/sbin/.jbroot" ] && [ ! -L "$root/sbin/.jbroot" ]; then ln -s ../.jbroot "$root/sbin/.jbroot"; echo "created-link:sbin"; fi
 test "$(readlink -f "$root/sbin/.jbroot")" = "$root"
fi
if [ -d "$root/usr/bin" ]; then
 if [ ! -e "$root/usr/bin/.jbroot" ] && [ ! -L "$root/usr/bin/.jbroot" ]; then ln -s ../../.jbroot "$root/usr/bin/.jbroot"; echo "created-link:usr/bin"; fi
 test "$(readlink -f "$root/usr/bin/.jbroot")" = "$root"
fi
if [ -d "$root/usr/lib" ]; then
 if [ ! -e "$root/usr/lib/.jbroot" ] && [ ! -L "$root/usr/lib/.jbroot" ]; then ln -s ../../.jbroot "$root/usr/lib/.jbroot"; echo "created-link:usr/lib"; fi
 test "$(readlink -f "$root/usr/lib/.jbroot")" = "$root"
fi
if [ -d "$root/usr/lib/bash" ]; then
 if [ ! -e "$root/usr/lib/bash/.jbroot" ] && [ ! -L "$root/usr/lib/bash/.jbroot" ]; then ln -s ../../../.jbroot "$root/usr/lib/bash/.jbroot"; echo "created-link:usr/lib/bash"; fi
 test "$(readlink -f "$root/usr/lib/bash/.jbroot")" = "$root"
fi
if [ -d "$root/usr/lib/engines-3" ]; then
 if [ ! -e "$root/usr/lib/engines-3/.jbroot" ] && [ ! -L "$root/usr/lib/engines-3/.jbroot" ]; then ln -s ../../../.jbroot "$root/usr/lib/engines-3/.jbroot"; echo "created-link:usr/lib/engines-3"; fi
 test "$(readlink -f "$root/usr/lib/engines-3/.jbroot")" = "$root"
fi
if [ -d "$root/usr/lib/gawk" ]; then
 if [ ! -e "$root/usr/lib/gawk/.jbroot" ] && [ ! -L "$root/usr/lib/gawk/.jbroot" ]; then ln -s ../../../.jbroot "$root/usr/lib/gawk/.jbroot"; echo "created-link:usr/lib/gawk"; fi
 test "$(readlink -f "$root/usr/lib/gawk/.jbroot")" = "$root"
fi
if [ -d "$root/usr/lib/inspector" ]; then
 if [ ! -e "$root/usr/lib/inspector/.jbroot" ] && [ ! -L "$root/usr/lib/inspector/.jbroot" ]; then ln -s ../../../.jbroot "$root/usr/lib/inspector/.jbroot"; echo "created-link:usr/lib/inspector"; fi
 test "$(readlink -f "$root/usr/lib/inspector/.jbroot")" = "$root"
fi
if [ -d "$root/usr/lib/ossl-modules" ]; then
 if [ ! -e "$root/usr/lib/ossl-modules/.jbroot" ] && [ ! -L "$root/usr/lib/ossl-modules/.jbroot" ]; then ln -s ../../../.jbroot "$root/usr/lib/ossl-modules/.jbroot"; echo "created-link:usr/lib/ossl-modules"; fi
 test "$(readlink -f "$root/usr/lib/ossl-modules/.jbroot")" = "$root"
fi
if [ -d "$root/usr/lib/pam" ]; then
 if [ ! -e "$root/usr/lib/pam/.jbroot" ] && [ ! -L "$root/usr/lib/pam/.jbroot" ]; then ln -s ../../../.jbroot "$root/usr/lib/pam/.jbroot"; echo "created-link:usr/lib/pam"; fi
 test "$(readlink -f "$root/usr/lib/pam/.jbroot")" = "$root"
fi
if [ -d "$root/usr/libexec" ]; then
 if [ ! -e "$root/usr/libexec/.jbroot" ] && [ ! -L "$root/usr/libexec/.jbroot" ]; then ln -s ../../.jbroot "$root/usr/libexec/.jbroot"; echo "created-link:usr/libexec"; fi
 test "$(readlink -f "$root/usr/libexec/.jbroot")" = "$root"
fi
if [ -d "$root/usr/libexec/apt" ]; then
 if [ ! -e "$root/usr/libexec/apt/.jbroot" ] && [ ! -L "$root/usr/libexec/apt/.jbroot" ]; then ln -s ../../../.jbroot "$root/usr/libexec/apt/.jbroot"; echo "created-link:usr/libexec/apt"; fi
 test "$(readlink -f "$root/usr/libexec/apt/.jbroot")" = "$root"
fi
if [ -d "$root/usr/libexec/apt/methods" ]; then
 if [ ! -e "$root/usr/libexec/apt/methods/.jbroot" ] && [ ! -L "$root/usr/libexec/apt/methods/.jbroot" ]; then ln -s ../../../../.jbroot "$root/usr/libexec/apt/methods/.jbroot"; echo "created-link:usr/libexec/apt/methods"; fi
 test "$(readlink -f "$root/usr/libexec/apt/methods/.jbroot")" = "$root"
fi
if [ -d "$root/usr/libexec/apt/solvers" ]; then
 if [ ! -e "$root/usr/libexec/apt/solvers/.jbroot" ] && [ ! -L "$root/usr/libexec/apt/solvers/.jbroot" ]; then ln -s ../../../../.jbroot "$root/usr/libexec/apt/solvers/.jbroot"; echo "created-link:usr/libexec/apt/solvers"; fi
 test "$(readlink -f "$root/usr/libexec/apt/solvers/.jbroot")" = "$root"
fi
if [ -d "$root/usr/libexec/awk" ]; then
 if [ ! -e "$root/usr/libexec/awk/.jbroot" ] && [ ! -L "$root/usr/libexec/awk/.jbroot" ]; then ln -s ../../../.jbroot "$root/usr/libexec/awk/.jbroot"; echo "created-link:usr/libexec/awk"; fi
 test "$(readlink -f "$root/usr/libexec/awk/.jbroot")" = "$root"
fi
if [ -d "$root/usr/libexec/coreutils" ]; then
 if [ ! -e "$root/usr/libexec/coreutils/.jbroot" ] && [ ! -L "$root/usr/libexec/coreutils/.jbroot" ]; then ln -s ../../../.jbroot "$root/usr/libexec/coreutils/.jbroot"; echo "created-link:usr/libexec/coreutils"; fi
 test "$(readlink -f "$root/usr/libexec/coreutils/.jbroot")" = "$root"
fi
if [ -d "$root/usr/libexec/git-core" ]; then
 if [ ! -e "$root/usr/libexec/git-core/.jbroot" ] && [ ! -L "$root/usr/libexec/git-core/.jbroot" ]; then ln -s ../../../.jbroot "$root/usr/libexec/git-core/.jbroot"; echo "created-link:usr/libexec/git-core"; fi
 test "$(readlink -f "$root/usr/libexec/git-core/.jbroot")" = "$root"
fi
if [ -d "$root/usr/libexec/sudo" ]; then
 if [ ! -e "$root/usr/libexec/sudo/.jbroot" ] && [ ! -L "$root/usr/libexec/sudo/.jbroot" ]; then ln -s ../../../.jbroot "$root/usr/libexec/sudo/.jbroot"; echo "created-link:usr/libexec/sudo"; fi
 test "$(readlink -f "$root/usr/libexec/sudo/.jbroot")" = "$root"
fi
if [ -d "$root/usr/local/lib" ]; then
 if [ ! -e "$root/usr/local/lib/.jbroot" ] && [ ! -L "$root/usr/local/lib/.jbroot" ]; then ln -s ../../../.jbroot "$root/usr/local/lib/.jbroot"; echo "created-link:usr/local/lib"; fi
 test "$(readlink -f "$root/usr/local/lib/.jbroot")" = "$root"
fi
if [ -d "$root/usr/sbin" ]; then
 if [ ! -e "$root/usr/sbin/.jbroot" ] && [ ! -L "$root/usr/sbin/.jbroot" ]; then ln -s ../../.jbroot "$root/usr/sbin/.jbroot"; echo "created-link:usr/sbin"; fi
 test "$(readlink -f "$root/usr/sbin/.jbroot")" = "$root"
fi
echo B29_LOADER_LINKS_OK
if [ ! -e "$root/etc/pwd.db" ] || [ ! -e "$root/etc/spwd.db" ]; then
 env -u DYLD_LIBRARY_PATH PATH=/usr/bin:/bin:/usr/sbin:/sbin DISABLE_TWEAKS=1 "$root/usr/sbin/pwd_mkdb" -p /etc/master.passwd
 chmod 644 "$root/etc/pwd.db"
 chmod 600 "$root/etc/spwd.db"
fi
env -u DYLD_LIBRARY_PATH PATH=/usr/bin:/bin:/usr/sbin:/sbin DISABLE_TWEAKS=1 "$root/usr/bin/ssh-keygen" -A
env -u DYLD_LIBRARY_PATH PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/root DISABLE_TWEAKS=1 "$root/bin/sh" -c 'set -eu; echo B29_VROOT_START; pwd; id root; id mobile; test -c /dev/null; : > /dev/null; test -d /rootfs/private; dpkg --version | head -2; apt --version; /usr/bin/curl --version | head -1; echo B29_VROOT_OK'
for item in firmware.list firmware.md5sums; do
 if [ ! -e "$root/Library/dpkg/info/$item" ]; then
  : > "$root/Library/dpkg/info/$item"
  chmod 644 "$root/Library/dpkg/info/$item"
  chown 0:0 "$root/Library/dpkg/info/$item"
  echo "created-virtual-package-metadata:$item"
 fi
done
env -u DYLD_LIBRARY_PATH PATH=/usr/bin:/bin:/usr/sbin:/sbin DISABLE_TWEAKS=1 "$root/usr/bin/dpkg" --audit
stat -c '%n %a %u:%g' "$root/etc/pwd.db" "$root/etc/spwd.db" "$root/etc/ssh/ssh_host_ed25519_key"
ls -l "$root/bin/sh" "$root/usr/bin/pager"
echo B29_POSTCHECK_OK

#!/bin/zsh
# One CFW install on the new stage-1 VM; no fallback target or automatic retry.
set -euo pipefail

project_root="${0:A:h:h:h}"
bundle="$project_root/.build/autophone-migration-20261031/DerivedData/Build/Products/Debug/VPhone.bundle"
cli="$bundle/Contents/MacOS/vphone-cli"
vm="$project_root/.build/am31/machines/baseline"
work="$project_root/.build/am31/cfw-work"
evidence="$project_root/research/autophone_migration_2026-10-30/evidence/stage1-20261031/runtime"

[[ "$EUID" -eq 0 ]]
[[ -d "$vm" && ! -L "$vm" && -f "$vm/Disk.img" && ! -L "$vm/Disk.img" ]]
[[ "$(/usr/bin/stat -f %u "$vm/Disk.img")" == 501 ]]
/usr/bin/codesign --verify --deep --strict "$bundle"
read -r cli_hash rest < <(/usr/bin/shasum -a 256 "$cli")
[[ "$cli_hash" == a5678c4490a5ad3903ffcb0a3e819b69487bd7213d68532504fbbcbf77ecb5a5 ]]

if /usr/sbin/lsof -t -- "$vm/Disk.img" > "$evidence/cfw-disk-holders.txt" 2> "$evidence/cfw-lsof.stderr"; then
    print -u2 -- "Refusing CFW install: target disk is open"
    exit 1
else
    lsof_status=$?
    [[ "$lsof_status" -eq 1 && ! -s "$evidence/cfw-lsof.stderr" ]]
fi

# A pre-existing folder refuses this one-shot invocation rather than reusing it.
/bin/mkdir -m 700 "$work"
export SUDO_UID=501 SUDO_GID=20 SUDO_USER=kolar
export VPHONE_ROOT="$project_root/.build/am31/cache"
exec "$cli" cfw install --library-root "$project_root/.build/am31/machines" baseline \
    --keep-artifacts --work-parent "$work"

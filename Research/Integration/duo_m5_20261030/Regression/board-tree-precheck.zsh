#!/bin/zsh
# Run manually in Terminal, as your normal user. Checks that `cfw
# update-environment` refuses a foldable guest without its board device tree
# before any disk work. Uses the disposable `duo-display-matrix` only: its
# FirmwareOriginals board tree is moved aside, the update is run once with the
# bundle built at .build/XcodeBoardTreeCheck, and the tree is put back
# whatever happens. Expected: a non-zero exit within seconds, the precondition
# message, no disk attach, and Disk.img / PatchReceipt.plist unchanged.
set -euo pipefail

repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
cli="$repo_root/.build/XcodeBoardTreeCheck/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli"
library="$repo_root/.build/acceptance/machines"
machine=duo-display-matrix
kept="$library/$machine/FirmwareOriginals/iPhone19,4_27.1_24A94425_Restore/Firmware/all_flash/DeviceTree.v68ap.im4p"
(( EUID != 0 )) || { print -u2 'Run as your normal user; the script invokes sudo once.'; exit 2; }
[[ -x "$cli" && -f "$kept" ]] || { print -u2 "Missing $cli or $kept"; exit 1; }
if pgrep -f "vphone-vm.*/$machine" > /dev/null; then print -u2 "$machine is running"; exit 1; fi

out="$repo_root/.build/acceptance/cases/board-tree-precheck-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out"
cp "${0:a}" "$out/driver.zsh"
stat_of() { /usr/bin/stat -f '%m %z' "$library/$machine/$1"; }
before_disk=$(stat_of Disk.img); before_receipt=$(/usr/bin/shasum -a 256 "$library/$machine/PatchReceipt.plist")

aside="$out/DeviceTree.v68ap.im4p"
mv "$kept" "$aside"
trap 'mv "$aside" "$kept"; print "Board tree restored."' EXIT

t0=$(date +%s)
set +e
sudo "$cli" cfw update-environment "$machine" -l "$library" > "$out/update.log" 2>&1
rc=$?
set -e
elapsed=$(( $(date +%s) - t0 ))

{
    print "exit=$rc elapsed=${elapsed}s lines=$(grep -c . "$out/update.log")"
    print "message: $(grep -m1 "need(s) the board's own device tree" "$out/update.log" || print none)"
    print "attached disk: $(grep -c -E '^/dev/disk' "$out/update.log")"
    print "Disk.img unchanged: $([[ "$(stat_of Disk.img)" == "$before_disk" ]] && print yes || print NO)"
    print "PatchReceipt unchanged: $([[ "$(/usr/bin/shasum -a 256 "$library/$machine/PatchReceipt.plist")" == "$before_receipt" ]] && print yes || print NO)"
} | tee "$out/results.txt"
print "Evidence: $out"

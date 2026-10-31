#!/bin/zsh
# Run manually in Terminal, as your normal user. Static display and inner
# cutout lifecycle on the disposable machine `duo-display-matrix` only:
#   P1 fold (control)            P2 outer
#   P3 inner, fold display on    P4 inner, cutout on, fold display off
#   P5 inner, cutout off         P6 inner, cutout on again
#   P7 fold restored (standard selection)
# Each phase runs display-check.zsh (windowed boot, checks, normal stop).
# sudo is used only for `cfw update-environment duo-display-matrix` before
# P4, P5, P6 and P7. --check performs the read-only checks and exits.
# --resume <evidence-dir> continues at P4 in a run whose P1-P3 already passed
# (they need no root), so only the sudo phases remain.
set -euo pipefail

repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
regression="${0:a:h}"
record="$repo_root/Research/Integration/duo_m5_20261030/validation.json"
bundle="$repo_root/.build/XcodeDuo/Build/Products/Debug/VPhone.bundle"
cli="$bundle/Contents/MacOS/vphone-cli"
library="$repo_root/.build/acceptance/machines"
machine=duo-display-matrix
fold_display=system-springboard-cfw-fold_display
inner_cutout=system-springboard-exp-inner_cutout
mode="${1:-run}"
[[ "$mode" == run || "$mode" == --check || "$mode" == --resume ]] \
    || { print -u2 'Expected no argument, --check or --resume <evidence-dir>'; exit 2; }
(( EUID != 0 )) || { print -u2 'Run as your normal user; the script invokes sudo for each root step.'; exit 2; }

codesign --verify --deep --strict "$bundle"
for relative in Contents/MacOS/vphone-cli Contents/MacOS/vphone-vm; do
    expected=$(jq -er --arg r "$relative" '.bundles.candidate.files[$r].sha256' "$record")
    actual=$(/usr/bin/shasum -a 256 "$bundle/$relative" | /usr/bin/awk '{print $1}')
    [[ "$actual" == "$expected" ]] || { print -u2 "Binary changed: $relative"; exit 1; }
done
[[ -f "$library/$machine/Disk.img" ]] || { print -u2 "Missing $machine"; exit 1; }
if pgrep -f "vphone-vm.*/$machine" > /dev/null; then print -u2 "$machine is running"; exit 1; fi
for file in Disk.img SEPStorage nvram.bin; do
    if /usr/sbin/lsof -nP "$library/$machine/$file" > /dev/null; then print -u2 "Open: $file"; exit 1; fi
done
print "Read-only checks passed: pinned candidate bundle; $machine stopped."
[[ "$mode" != --check ]] || exit 0

if [[ "$mode" == --resume ]]; then
    run_root="${2:?--resume needs the evidence directory}"
    for phase in P1-fold P2-outer P3-inner-folddisplay; do
        [[ -f "$run_root/$phase/results.txt" ]] || { print -u2 "Missing $phase in $run_root"; exit 1; }
    done
    [[ ! -e "$run_root/P4-inner-cutout-on" ]] || { print -u2 "P4 already started in $run_root"; exit 1; }
    cp "${0:a}" "$run_root/driver-resume.zsh"
else
    run_root="$repo_root/.build/acceptance/cases/display-matrix-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$run_root"
    cp "${0:a}" "$run_root/driver.zsh"
fi
print "Evidence: $run_root"
select_patches() { # select_patches <phase> [set-patches options]
    local phase="$1"; shift
    "$cli" fw set-patches "$machine" -l "$library" "$@" 2>&1 | tee "$run_root/$phase-set-patches.log"
}
display() { "$cli" vm config "$machine" -l "$library" --display "$2" 2>&1 | tee "$run_root/$1-display.log"; }
update_environment() {
    print "sudo: cfw update-environment $machine (phase $1)"
    sudo "$cli" cfw update-environment "$machine" -l "$library" 2>&1 | tee "$run_root/$1-update.log"
    cp "$library/$machine/PatchReceipt.plist" "$run_root/$1-PatchReceipt.plist"
}
check() { zsh "$regression/display-check.zsh" "$machine" "$run_root/$1" || print -u2 "Phase $1 check failed"; }

if [[ "$mode" == --resume ]]; then
    display P4-pre inner
else
    display P1 fold; check P1-fold
    display P2 outer; check P2-outer
    display P3 inner; check P3-inner-folddisplay
fi
select_patches P4 --block $fold_display --allow $inner_cutout
update_environment P4; check P4-inner-cutout-on
select_patches P5 --block $fold_display
update_environment P5; check P5-inner-cutout-off
select_patches P6 --block $fold_display --allow $inner_cutout
update_environment P6; check P6-inner-cutout-on-again
display P7 fold
select_patches P7
update_environment P7; check P7-fold-restored
jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg evidence "$run_root" '{completed_at:$at,evidence:$evidence}' \
    > "$run_root/complete.json"
print "Display matrix complete. Evidence: $run_root"

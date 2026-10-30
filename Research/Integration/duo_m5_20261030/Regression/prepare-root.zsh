#!/bin/zsh
# Run manually in Terminal. --check performs only read-only preparation checks.
# The default run uses sudo for two isolated CFW updates and AMFI admission.
set -euo pipefail

repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
record="$repo_root/Research/Integration/duo_m5_20261030/validation.json"
preparation="$repo_root/Research/Integration/duo_m5_20261030/runtime-preparation.json"
baseline="$repo_root/.build/validation/baseline/artifacts/VPhone.bundle"
candidate="$repo_root/.build/XcodeDuo/Build/Products/Debug/VPhone.bundle"
library="$repo_root/.build/acceptance/machines"
mode="${1:-run}"
[[ "$mode" == run || "$mode" == --check ]] || { print -u2 'Expected no argument or --check'; exit 2; }
(( EUID != 0 )) || { print -u2 'Run as your normal user; the script invokes sudo for each root step.'; exit 2; }

verify_bundle() {
    local label="$1" bundle="$2" relative expected actual
    codesign --verify --deep --strict "$bundle"
    expected=$(jq -er --arg label "$label" '.bundles[$label].bundle_cdhash' "$preparation")
    actual=$(codesign -dvvv "$bundle" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')
    [[ "$actual" == "$expected" ]] || { print -u2 "Bundle changed: $label"; return 1; }
    for relative in Contents/MacOS/vphone-cli Contents/MacOS/vphone-vm; do
        expected=$(jq -er --arg label "$label" --arg relative "$relative" \
            '.bundles[$label].files[$relative].sha256' "$record")
        actual=$(/usr/bin/shasum -a 256 "$bundle/$relative" | /usr/bin/awk '{print $1}')
        [[ "$actual" == "$expected" ]] || { print -u2 "Binary changed: $label/$relative"; return 1; }
    done
}
verify_stopped() {
    local name="$1" file readers_result
    [[ -f "$library/$name/config.plist" && -f "$library/$name/Disk.img" ]]
    for file in Disk.img SEPStorage nvram.bin; do
        if /usr/sbin/lsof -nP "$library/$name/$file"; then
            print -u2 "State file is open: $name/$file"
            return 1
        else
            readers_result=$?
            (( readers_result == 1 )) || return "$readers_result"
        fi
    done
}

verify_bundle baseline "$baseline"
verify_bundle candidate "$candidate"
verify_stopped duo-baseline-20261030
verify_stopped duo-candidate-20261030
print 'Read-only checks passed: signed/pinned bundles; both isolated VMs stopped.'
[[ "$mode" != --check ]] || exit 0

log_root="$repo_root/.build/acceptance/logs/root-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$log_root"
print "Updating only the two isolated VMs below $library"
print "Logs: $log_root"
sudo "$baseline/Contents/MacOS/vphone-cli" cfw update-environment duo-baseline-20261030 -l "$library" \
    2>&1 | tee "$log_root/baseline-update.log"
cp "$library/duo-baseline-20261030/PatchReceipt.plist" "$log_root/baseline-PatchReceipt.plist"
sudo "$candidate/Contents/MacOS/vphone-cli" cfw update-environment duo-candidate-20261030 -l "$library" \
    2>&1 | tee "$log_root/candidate-update.log"
cp "$library/duo-candidate-20261030/PatchReceipt.plist" "$log_root/candidate-PatchReceipt.plist"
sudo "$candidate/Contents/MacOS/vphone-escalator" allow \
    "$baseline/Contents/MacOS/vphone-vm" "$candidate/Contents/MacOS/vphone-vm" \
    2>&1 | tee "$log_root/allowlist.log"
jq -n --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg logs "$log_root" \
    '{completed_at:$completed_at,logs:$logs,baseline_update:true,candidate_update:true,allowlist:true}' \
    > "$repo_root/.build/acceptance/root-steps-complete.json"
print 'Root preparation completed; no VM has been started by this script.'

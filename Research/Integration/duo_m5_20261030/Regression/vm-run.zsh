#!/bin/zsh
# Run one isolated acceptance VM in the foreground. Use its matching bundle.
set -euo pipefail

repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
variant="${1:?usage: vm-run.zsh <baseline|candidate> <new-case-name> [--check|--windowed]}"
case_name="${2:?a new case name is required}"
mode="${3:-}"
[[ -z "$mode" || "$mode" == --check || "$mode" == --windowed ]] || exit 2
[[ "$case_name" == [a-zA-Z0-9]* && "$case_name" != *[^a-zA-Z0-9_-]* ]] || exit 2
case "$variant" in
    baseline) bundle="$repo_root/.build/validation/baseline/artifacts/VPhone.bundle" ;;
    candidate) bundle="$repo_root/.build/XcodeDuo/Build/Products/Debug/VPhone.bundle" ;;
    *) print -u2 'Expected baseline or candidate'; exit 2 ;;
esac
library="$repo_root/.build/acceptance/machines"
machine="duo-$variant-20261030"
case_root="$repo_root/.build/acceptance/cases/$case_name"
jq -e '.baseline_update==true and .candidate_update==true and .allowlist==true' \
    "$repo_root/.build/acceptance/root-steps-complete.json" >/dev/null
[[ ! -e "$case_root" ]] || { print -u2 "Case already exists: $case_root"; exit 2; }
for executable in vphone-cli vphone-vm; do
    expected=$(jq -er --arg variant "$variant" --arg file "Contents/MacOS/$executable" \
        '.bundles[$variant].files[$file].sha256' "$repo_root/Research/Integration/duo_m5_20261030/validation.json")
    actual=$(shasum -a 256 "$bundle/Contents/MacOS/$executable")
    [[ "${actual%% *}" == "$expected" ]] || { print -u2 "Unexpected binary: $executable"; exit 1; }
done
codesign --verify --deep --strict "$bundle"
if [[ "$mode" == --check ]]; then
    print "Validated $variant root marker, pinned CLI/VM hashes and signature; no VM launched."
    exit 0
fi
mkdir -p "$case_root"
git -C "$repo_root" rev-parse HEAD > "$case_root/driver-source-sha.txt"
cp "${0:a}" "$case_root/driver.zsh"
shasum -a 256 "${0:a}" > "$case_root/driver-sha256.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$case_root/started-at.txt"
print -r -- "$$" > "$case_root/driver.pid"
print -r -- "$machine" > "$case_root/machine.txt"
print -r -- "$bundle" > "$case_root/bundle.txt"
cp "$library/$machine/PatchReceipt.plist" "$case_root/PatchReceipt-before-boot.plist"
codesign -dvvv "$bundle/Contents/MacOS/vphone-vm" > "$case_root/signature.txt" 2>&1
# Windowed runs exercise the VM view's touch path and its recorder.
launch_mode=(--headless)
[[ "$mode" == --windowed ]] && launch_mode=()
print -r -- "${mode:-headless}" > "$case_root/launch-mode.txt"
print "Booting $machine; evidence: $case_root"
exec "$bundle/Contents/MacOS/vphone-cli" vm launch "$machine" -l "$library" $launch_mode -v \
    > "$case_root/boot.log" 2>&1

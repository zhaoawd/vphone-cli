#!/bin/zsh
# Firmware-free CLI regression. Creates only new fixture directories, keeps
# its evidence, and never launches a VM or uses the default machine library.
set -euo pipefail

repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
cli_path="${1:?usage: display-config.zsh <vphone-cli> [new-evidence-directory]}"
evidence_root="${2:-$repo_root/.build/validation/display/cli-$(uuidgen)}"
[[ -x "$cli_path" ]] || { print -u2 "CLI is not executable: $cli_path"; exit 1; }
[[ ! -e "$evidence_root" ]] || { print -u2 "Evidence directory must be new: $evidence_root"; exit 1; }
mkdir -p "$evidence_root/library/duo" "$evidence_root/library/plain"
library_root="$evidence_root/library"
duo_config="$library_root/duo/config.plist"
plain_config="$library_root/plain/config.plist"

run_config() {
    "$cli_path" vm config "$1" -l "$library_root" "${@:2}"
}
expect_value() {
    local actual=$(/usr/bin/plutil -extract "$2" raw -o - "$1")
    [[ "$actual" == "$3" ]] || { print -u2 "$2: expected $3, got $actual"; exit 1; }
}
expect_failure() {
    local tag="$1"; shift
    if "$@" > "$evidence_root/$tag.log" 2>&1; then
        print -u2 "Unexpected success: $tag"
        exit 1
    fi
}
expect_screen() {
    expect_value "$duo_config" screenConfig.width "$1"
    expect_value "$duo_config" screenConfig.height "$2"
    expect_value "$duo_config" screenConfig.pixelsPerInch 460
    expect_value "$duo_config" guestProductType iPhone19,4
    expect_value "$duo_config" cpuCount 8
}

"$cli_path" vm write-manifest --vm-dir "$library_root/duo" > "$evidence_root/create-duo.log"
"$cli_path" vm write-manifest --vm-dir "$library_root/plain" > "$evidence_root/create-plain.log"
/usr/bin/plutil -insert guestProductType -string iPhone19,4 "$duo_config"
/usr/bin/plutil -convert xml1 -o "$evidence_root/original.plist" "$duo_config"

run_config duo --display INNER > "$evidence_root/inner.log"
expect_screen 2007 2853
[[ "$(<"$library_root/duo/display-choice")" == inner ]]
/usr/bin/plutil -convert xml1 -o "$evidence_root/inner.plist" "$duo_config"
/usr/bin/plutil -remove screenConfig "$evidence_root/original.plist"
/usr/bin/plutil -remove screenConfig "$evidence_root/inner.plist"
cmp "$evidence_root/original.plist" "$evidence_root/inner.plist"

# Invalid display options must fail before writing any unrelated edit.
cp "$duo_config" "$evidence_root/before-invalid.plist"
expect_failure invalid-display run_config duo --display invalid --cpu 3
cmp "$duo_config" "$evidence_root/before-invalid.plist"
[[ "$(<"$library_root/duo/display-choice")" == inner ]]

run_config duo --display outer > "$evidence_root/outer.log"
expect_screen 1398 2034
[[ "$(<"$library_root/duo/display-choice")" == outer ]]
run_config duo --display fold > "$evidence_root/fold.log"
expect_screen 1398 2034
[[ ! -e "$library_root/duo/display-choice" ]]

cp "$plain_config" "$evidence_root/before-unsupported.plist"
expect_failure single-display run_config plain --display inner --cpu 3
cmp "$plain_config" "$evidence_root/before-unsupported.plist"
[[ ! -e "$library_root/plain/display-choice" ]]

print 'Display CLI regression: passed (inner/outer/fold, persistence, unchanged fields, invalid options, unsupported guest)'
print "Evidence: $evidence_root"

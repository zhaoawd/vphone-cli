#!/bin/zsh
set -euo pipefail
root="${0:a:h:h}"
out="$root/../.build/fold-display-tests"
mkdir -p "$out"
flags=()
if [[ "${1:-}" == --panel-source ]]; then
    flags+=("-DVP_PANEL_TEST_SOURCE=\"${2:A}\"")
elif (( $# )); then
    print -u2 'Expected --panel-source <source>'
    exit 2
fi
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
    -I"$root/FoldDisplay" "${flags[@]}" \
    "$root/Tests/FoldDisplayPanelPowerTests.m" -framework Foundation -framework CoreGraphics \
    -o "$out/fold-display-panel-power-tests"
"$out/fold-display-panel-power-tests"

#!/bin/zsh
set -euo pipefail
root="${0:a:h:h}"
out="$root/../.build/fold-display-tests"
mkdir -p "$out"
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    "$root/Tests/FoldDisplayWakeTests.m" "$root/FoldDisplay/FoldDisplayWake.m" \
    -framework Foundation -framework CoreGraphics -o "$out/fold-display-wake-tests"
"$out/fold-display-wake-tests"

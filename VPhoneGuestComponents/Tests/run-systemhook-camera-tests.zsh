#!/bin/zsh
set -euo pipefail
components=${0:a:h:h}
source_file=${VPHONE_SYSTEMHOOK_SOURCE:-$components/SystemHook/SystemHook-vphone.c}
temporary=$(mktemp -d "${TMPDIR:-/tmp}/vphone-systemhook-camera.XXXXXXXX")
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/SystemHook"
ln -s "$components/Shared" "$temporary/Shared"
cp "$source_file" "$temporary/SystemHook/SystemHook-vphone.c"
xcrun --sdk macosx clang -O2 -Wno-macro-redefined -Wno-unused-function \
    -DVPHONE_SYSTEMHOOK_SOURCE="\"$temporary/SystemHook/SystemHook-vphone.c\"" \
    "$components/Tests/SystemHookCameraTests.c" -o "$temporary/tests"
"$temporary/tests"

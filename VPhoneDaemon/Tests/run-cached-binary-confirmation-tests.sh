#!/bin/zsh
set -euo pipefail
tests="${0:a:h}"
native="${1:-${tests:h}/Native/vphoned_native.m}"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/vphone-cache-confirmation.XXXXXXXX")
trap 'rm -rf "$temporary"' EXIT
{
    cat "$tests/CachedBinaryConfirmationFixture.hfrag"
    sed -n '/^void vp_native_confirm_cached_binary(void) {/,/^}/p' "$native"
    cat "$tests/CachedBinaryConfirmationFixture.cfrag"
} > "$temporary/confirmation.c"
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -Wno-unused-function \
    -I"${tests:h}/Native/Include" "$temporary/confirmation.c" -o "$temporary/confirmation"
"$temporary/confirmation" "$temporary"

#!/bin/zsh
set -euo pipefail

tests="${0:a:h}"
source="${1:-${tests:h}/MobileRecoveryCore/libirecovery.c}"
out="$(mktemp -d "${TMPDIR:-/tmp}/vphone-recovery-client-tests.XXXXXX")"
trap 'rm -rf "$out"' EXIT

# Compile the production open routine against a fake USB backend.
{
    cat "$tests/RecoveryClientFixture.hfrag"
    awk '
        /^irecv_error_t irecv_open_with_ecid\(/ { capture = 1 }
        capture { print }
        capture && /^}/ { exit }
    ' "$source"
    cat "$tests/RecoveryClientFixture.cfrag"
} > "$out/recovery-client.c"
"${CC:-clang}" -std=c11 -Wall -Wextra -Werror "$out/recovery-client.c" -o "$out/recovery-client"
"$out/recovery-client"

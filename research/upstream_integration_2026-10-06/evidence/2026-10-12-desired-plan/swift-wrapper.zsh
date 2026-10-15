#!/bin/zsh
set -euo pipefail
if [[ "${1:-}" == test ]]; then
    exec /usr/bin/swift "$@" --force-resolved-versions
fi
exec /usr/bin/swift "$@"

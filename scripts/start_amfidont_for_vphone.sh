#!/bin/zsh
# start_amfidont_for_vphone.sh — Start amfidont for the current vphone build.
#
# This is the README "Option 2" host workaround packaged for this repo:
# - uses the project path so amfidont covers binaries relevant for the project
# - starts amfidont in daemon mode so signed vphone-cli launches are allowlisted
# - spoofs signatures to be recognized as apple signed for patchless variant

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
RELEASE_BIN="${PROJECT_ROOT}/.build/release/vphone-cli"
BUNDLE_BIN="${PROJECT_ROOT}/.build/vphone-cli.app/Contents/MacOS/vphone-cli"

find_amfidont() {
  if [[ -n "${AMFIDONT:-}" ]]; then
    if [[ -x "$AMFIDONT" ]]; then
      echo "$AMFIDONT"
      return 0
    fi
    echo "AMFIDONT is set but not executable: $AMFIDONT" >&2
    return 1
  fi

  local found
  found="$(command -v amfidont 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi

  local user_base user_bin
  user_base="$(xcrun python3 -m site --user-base 2>/dev/null || true)"
  user_bin="${user_base}/bin/amfidont"
  if [[ -n "$user_base" && -x "$user_bin" ]]; then
    echo "$user_bin"
    return 0
  fi

  return 1
}

url_encode_path() {
  xcrun python3 - "$1" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe="/"))
PY
}

cdhash_for_binary() {
  local binary="$1"
  [[ -f "$binary" ]] || return 0
  { codesign -d -vvvv "$binary" 2>&1 || true; } | awk -F= '/^CDHash=/ { print $2; exit }'
}

AMFIDONT_BIN="$(find_amfidont || true)"
if [[ -z "$AMFIDONT_BIN" ]]; then
  echo "amfidont not found" >&2
  echo "Install it first: xcrun python3 -m pip install -U amfidont" >&2
  echo "If it is already installed, either add the Python user bin directory to PATH or set AMFIDONT=/path/to/amfidont." >&2
  exit 1
fi

ENCODED_PROJECT_ROOT="$(url_encode_path "$PROJECT_ROOT")"

args=(daemon --path "$PROJECT_ROOT")
if [[ "$ENCODED_PROJECT_ROOT" != "$PROJECT_ROOT" ]]; then
  args+=(--path "$ENCODED_PROJECT_ROOT")
fi

seen_cdhashes=""
for binary in "$RELEASE_BIN" "$BUNDLE_BIN"; do
  cdhash="$(cdhash_for_binary "$binary")"
  if [[ -n "$cdhash" && "$seen_cdhashes" != *":$cdhash:"* ]]; then
    args+=(--cdhash "$cdhash")
    seen_cdhashes="${seen_cdhashes}:${cdhash}:"
  fi
done

sudo "$AMFIDONT_BIN" "${args[@]}" --spoof-apple >/dev/null 2>&1

echo "amfidont started"

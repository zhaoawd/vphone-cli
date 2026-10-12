#!/bin/zsh
# Controlled R6/R7/R8 commands. Requires explicit approval before execution.
set -euo pipefail
BUILD_ROOT=/private/tmp/vphone-v2-build-20261002
TEST_ROOT=/Users/kolar/vphone-v2-accept-20261002
VM=lp-v2-accept-20261002
CLI="$BUILD_ROOT/.build/vphone-cli.app/Contents/MacOS/vphone-cli"
CANDIDATES="$BUILD_ROOT/.build/acceptance-r567-20261002"
export VPHONE_ROOT="$TEST_ROOT"
export VPHONE_PYTHON=/Users/kolar/github/vphone-cli/.venv/bin/python3
phase="${1:?phase: offline-check|offline-update|online-update|online-restart|online-status|rollback}"
case "$phase" in
  offline-check|offline-update)
    report=$(mktemp)
    trap 'rm -f "$report"' EXIT
    "$CLI" cfw update-environment "$VM" --library-root "$TEST_ROOT/VMs" \
      --project-root "$BUILD_ROOT" --components "$CANDIDATES/r6-cam-O1/stage" \
      --check --root-popup > "$report"
    cat "$report"
    python3 - "$report" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))
assert x['classification']=='offline_update',x['classification']
assert x['replace']==['libcamfix.dylib'],x['replace']
assert x['disk']['unchanged'] is True
PY
    if [[ "$phase" == offline-update ]]; then
      "$CLI" cfw update-environment "$VM" --library-root "$TEST_ROOT/VMs" \
        --project-root "$BUILD_ROOT" --components "$CANDIDATES/r6-cam-O1/stage" --root-popup
    fi
    ;;
  online-update|online-restart|online-status)
    command=update
    extra=()
    [[ "$phase" == online-status ]] && command=status
    [[ "$phase" == online-restart ]] && extra=(--restart cameracaptured)
    "$CLI" guest env "$command" "$VM" --library-root "$TEST_ROOT/VMs" \
      --components "$CANDIDATES/r7-vcam-O1/stage" "${extra[@]}"
    ;;
  rollback)
    transaction="${2:?R7 transaction ID required}"
    "$CLI" guest env rollback "$VM" "$transaction" --library-root "$TEST_ROOT/VMs"
    ;;
  *) print -u2 'unknown phase'; exit 64 ;;
esac

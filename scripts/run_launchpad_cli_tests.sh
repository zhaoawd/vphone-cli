#!/bin/zsh
# run_launchpad_cli_tests.sh — Launchpad tests against the embedded vphone-cli
# (T26 B6, `make test_launchpad_cli`).
#
# Runs RealCLIEditTests (B3: vm new/config/rename/clone/export/import/delete
# on fixtures) and RealCLICreateTests (B4: fw catalog --json, vm create --help,
# vm create-status --json) with the vphone-cli embedded in
# .build/vphone-launchpad.app, verified as the app verifies it. Every command
# names a temporary --library-root; VPHONE_LIBRARY_ROOT points at an empty
# temporary folder, never at ~/.vphone/VMs. Nothing boots, downloads, restores
# or runs vm create.
#
# Not part of `make test`, `make test_swift` or CI: it needs `make launchpad`
# first, and its fixtures write sparse disk images.
#
# Usage: zsh scripts/run_launchpad_cli_tests.sh   (normally via make)
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

APP="${PROJECT_ROOT}/.build/vphone-launchpad.app"
SUITES=(RealCLIEditTests RealCLICreateTests)

if [[ ! -d "$APP" ]]; then
  print -u2 -- "Missing ${APP}; run make launchpad first."
  exit 1
fi

LIBRARY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lp-cli.XXXXXX")"
LOG="$(mktemp "${TMPDIR:-/tmp}/lp-cli-log.XXXXXX")"
cleanup() {
  rm -f "$LOG"
  # Remove the library root only while it is empty; anything left is reported.
  [[ -d "$LIBRARY_ROOT" ]] && rmdir "$LIBRARY_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

if [[ "${LIBRARY_ROOT:A}" == "${HOME}/.vphone/VMs"* ]]; then
  print -u2 -- "Refusing a library root under ~/.vphone/VMs: ${LIBRARY_ROOT}"
  exit 1
fi

echo "=== Launchpad CLI tests: ${APP} ==="
echo "  VPHONE_LIBRARY_ROOT=${LIBRARY_ROOT}"
set +e
VPHONE_LAUNCHPAD_APP="$APP" VPHONE_LIBRARY_ROOT="$LIBRARY_ROOT" \
  swift test --disable-sandbox --filter "${(j:|:)SUITES}" 2>&1 | tee "$LOG"
test_status=${pipestatus[1]}
set -e

failed=0
if (( test_status != 0 )); then
  print -u2 -- "swift test exited ${test_status}"
  failed=1
fi
# Each suite must have run, not been skipped.
for suite in $SUITES; do
  if ! grep -q "Suite ${suite} passed" "$LOG"; then
    print -u2 -- "Suite ${suite} did not pass (skipped or failed)"
    failed=1
  fi
done
leftover=("$LIBRARY_ROOT"/*(DN))
if (( ${#leftover} != 0 )); then
  print -u2 -- "VPHONE_LIBRARY_ROOT is not empty after the run: ${LIBRARY_ROOT}"
  failed=1
fi
if (( failed )); then
  exit 1
fi
echo "=== Launchpad CLI tests passed: ${(j:, :)SUITES}; temporary library root empty and removed ==="

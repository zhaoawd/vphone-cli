#!/bin/zsh
# Approved 2026-10-02 MAC mount comparison, restricted to the new experiment VM.
set -euo pipefail
BUILD_ROOT=/private/tmp/vphone-v2-mount-build-20261002
BASE_BUILD=/private/tmp/vphone-v2-build-20261002
TEST_ROOT=/Users/kolar/vphone-v2-accept-20261002
VM=lp-v2-mount-accept-20261002
CLI="$BUILD_ROOT/.build/vphone-cli.app/Contents/MacOS/vphone-cli"
CANDIDATES="$BASE_BUILD/.build/acceptance-r567-20261002"
export VPHONE_ROOT="$TEST_ROOT"
export VPHONE_PYTHON=/Users/kolar/github/vphone-cli/.venv/bin/python3
export VPHONE_GUEST_COMPONENTS="$CANDIDATES/r6-cam-O1/stage"
export VPHONE_API_DAEMON="$BASE_BUILD/.build/daemon-api-v2/candidate-v2"
phase="${1:?phase: preflight|create|check|launch|status|update|restart|rollback|stop}"
case "$phase" in
  preflight)
    VPHONE_CLI_BIN="$BUILD_ROOT/.build/vphone-cli.app/Contents/MacOS/vphone-vm" \
      zsh "$BUILD_ROOT/scripts/boot_host_preflight.sh" --assert-bootable
    ;;
  create)
    [[ ! -e "$TEST_ROOT/VMs/$VM" ]] || { print -u2 'experiment VM already exists'; exit 64; }
    zsh "$0" preflight
    "$CLI" vm create "$VM" --library-root "$TEST_ROOT/VMs" --variant regular \
      --guest-environment v2 --experimental-v2-root-remount --disk-size 64 --keep-artifacts \
      --iphone-source '/Users/kolar/.vphone/ipsws/iPhone17,3_26.1_23B85_Restore.ipsw' \
      --cloudos-source '/Users/kolar/.vphone/ipsws/399b664dd623358c3de118ffc114e42dcd51c9309e751d43-727c4f5e2432.ipsw' \
      --project-root "$BUILD_ROOT" --root-popup -v
    ;;
  check)
    "$CLI" cfw update-environment "$VM" --library-root "$TEST_ROOT/VMs" \
      --project-root "$BUILD_ROOT" --components "$VPHONE_GUEST_COMPONENTS" --check --root-popup
    ;;
  launch)
    [[ -n "${VPHONE_API_TOKEN:-}" ]] || { print -u2 'VPHONE_API_TOKEN required'; exit 64; }
    "$CLI" vm launch "$VM" --library-root "$TEST_ROOT/VMs" \
      --project-root "$BUILD_ROOT" --api-listen 127.0.0.1:18081 -v
    ;;
  status|update|restart)
    command=status
    extra=()
    [[ "$phase" != status ]] && command=update
    [[ "$phase" == restart ]] && extra=(--restart cameracaptured)
    "$CLI" guest env "$command" "$VM" --library-root "$TEST_ROOT/VMs" \
      --components "$CANDIDATES/r7-vcam-O1/stage" "${extra[@]}"
    ;;
  rollback)
    transaction="${2:?successful R7 transaction ID required}"
    "$CLI" guest env rollback "$VM" "$transaction" --library-root "$TEST_ROOT/VMs"
    ;;
  stop)
    "$CLI" vm stop "$VM" --library-root "$TEST_ROOT/VMs"
    ;;
  *) print -u2 'unknown phase'; exit 64 ;;
esac

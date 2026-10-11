#!/bin/zsh
# Build and sign the local guest daemon variants before packaging or installation.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"
command -v ldid >/dev/null || { echo 'ldid missing; run make setup_tools' >&2; exit 1; }
GUEST_OUT="$PROJECT_ROOT/.build/guest"
mkdir -p "$GUEST_OUT"
GUEST_HASH="$(git rev-parse --short HEAD)"
for kind in vphoned vphoned-less; do
  extra=""
  [[ "$kind" == vphoned-less ]] && extra="-DLESS=1"
  make -B -C "$SCRIPT_DIR/vphoned" OUT="$GUEST_OUT/$kind" \
    GIT_HASH="$GUEST_HASH" EXTRA_CFLAGS="$extra"
  ldid -S"$SCRIPT_DIR/vphoned/entitlements.plist" -M \
    "-K$SCRIPT_DIR/vphoned/signcert.p12" "$GUEST_OUT/$kind"
done
cp "$SCRIPT_DIR/vphoned/vphoned.plist" "$GUEST_OUT/vphoned.plist"
cp "$SCRIPT_DIR/vphoned/entitlements.plist" "$GUEST_OUT/vphoned.entitlements.plist"
python3 "$SCRIPT_DIR/check_guest_payloads.py" "$GUEST_OUT" --record

# 默认组合：classic 控制/相机和独立固定 API，不覆盖 classic 更新载荷。
zsh "$SCRIPT_DIR/build_daemon_api.sh"
python3 "$SCRIPT_DIR/check_guest_api.py" --stage-api "$PROJECT_ROOT/.build/daemon-api-v2/candidate" "$GUEST_OUT" --record

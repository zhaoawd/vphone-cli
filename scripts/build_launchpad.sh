#!/bin/zsh
# build_launchpad.sh — Assemble .build/vphone-launchpad.app (T26 B1).
#
# Embeds the already built .build/vphone-cli.app (make build / make bundle)
# as Contents/Helpers/vphone-cli.app without re-signing it, records the
# cdhashes of its vphone-cli and vphone-vm in
# Contents/Resources/embedded-toolchain.json, then signs the outer app ad hoc
# (no entitlements, no --deep). The outer signature seals the manifest;
# Launchpad refuses to run any other executable.
#
# Usage: zsh scripts/build_launchpad.sh   (normally via `make launchpad`)
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

TOOLCHAIN=".build/vphone-cli.app"
APP=".build/vphone-launchpad.app"
HELPER="${APP}/Contents/Helpers/vphone-cli.app"
INFO_PLIST="sources/VPhoneLaunchpad-Info.plist"
RESOURCE_BUNDLE="vphone-cli_VPhoneLaunchpad.bundle"
BUNDLE_ID="com.vphone.cli.launchpad"
GIT_HASH="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

cdhash() {
  codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1
}

# --- Embedded toolchain must be complete and verified first ---
echo "=== Checking ${TOOLCHAIN} ==="
if [[ ! -d "$TOOLCHAIN" ]]; then
  print -u2 -- "Missing ${TOOLCHAIN}; run make build first."
  exit 1
fi
python3 "$SCRIPT_DIR/check_bundle.py" "$TOOLCHAIN"

# --- Launchpad executable and compiled string catalogs ---
echo "=== Building vphone-launchpad (${GIT_HASH}) ==="
swift build -c release --force-resolved-versions --product vphone-launchpad
BIN_DIR="$(swift build -c release --show-bin-path)"
BINARY="${BIN_DIR}/vphone-launchpad"
LPROJ_DIR="${BIN_DIR}/${RESOURCE_BUNDLE}/Contents/Resources"
[[ -x "$BINARY" ]] || { print -u2 -- "Missing ${BINARY}"; exit 1; }
[[ -d "$LPROJ_DIR" ]] || { print -u2 -- "Missing compiled catalogs in ${LPROJ_DIR}"; exit 1; }

# --- Assemble ---
echo "=== Assembling ${APP} ==="
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/Helpers"
cp -f "$BINARY" "${APP}/Contents/MacOS/vphone-launchpad"
cp -f "$INFO_PLIST" "${APP}/Contents/Info.plist"
cp -f sources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
# SwiftPM compiles the catalogs into its resource bundle. Bundle.main and
# SwiftUI look in the app's own Resources, so the .lproj folders go there.
for lproj in "$LPROJ_DIR"/*.lproj(N); do
  cp -R "$lproj" "${APP}/Contents/Resources/"
done

# APFS clone: the 146 MB toolchain takes no extra space and keeps its
# signatures byte for byte. Other volumes get a full copy.
if ! cp -cR "$TOOLCHAIN" "$HELPER" 2>/dev/null; then
  print -- "  note: APFS clone unavailable; copying ${TOOLCHAIN} (full size)"
  rm -rf "$HELPER"
  cp -R "$TOOLCHAIN" "$HELPER"
fi

# --- Manifest of the embedded executables ---
CLI_CDHASH="$(cdhash "${HELPER}/Contents/MacOS/vphone-cli")"
VM_CDHASH="$(cdhash "${HELPER}/Contents/MacOS/vphone-vm")"
REF_CLI_CDHASH="$(cdhash "${TOOLCHAIN}/Contents/MacOS/vphone-cli")"
REF_VM_CDHASH="$(cdhash "${TOOLCHAIN}/Contents/MacOS/vphone-vm")"
if [[ -z "$CLI_CDHASH" || -z "$VM_CDHASH" || "$CLI_CDHASH" != "$REF_CLI_CDHASH" || "$VM_CDHASH" != "$REF_VM_CDHASH" ]]; then
  print -u2 -- "Embedded toolchain cdhash differs from ${TOOLCHAIN}: cli ${CLI_CDHASH}/${REF_CLI_CDHASH} vm ${VM_CDHASH}/${REF_VM_CDHASH}"
  exit 1
fi
python3 - "${APP}/Contents/Resources/embedded-toolchain.json" "$GIT_HASH" "$CLI_CDHASH" "$VM_CDHASH" <<'PY'
import json, sys
path, git_hash, cli, vm = sys.argv[1:]
manifest = {
    'schema': 'vphone.launchpad.embedded-toolchain',
    'version': 1,
    'gitHash': git_hash,
    'vphoneCLI': {'cdhash': cli},
    'vphoneVM': {'cdhash': vm},
}
with open(path, 'w') as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write('\n')
PY
echo "  vphone-cli cdhash ${CLI_CDHASH}"
echo "  vphone-vm  cdhash ${VM_CDHASH}"

# --- Seal: outer app only, ad hoc, no entitlements ---
echo "=== Signing ${APP} ==="
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
python3 "$SCRIPT_DIR/check_launchpad_bundle.py" "$APP" --reference "$TOOLCHAIN"

echo ""
echo "=== Launchpad build complete ==="
echo "  app : ${APP}"
echo "Run: open ${APP}"

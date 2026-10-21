#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="/Users/kolar/github/vphone-cli/scripts"
PROJECT_ROOT="/Users/kolar/github/vphone-cli"
cd "$PROJECT_ROOT"
BUNDLE=".build/t51-runtime-cli-20261021.app"
BINARY=".build/release/vphone-cli"
RES="${BUNDLE}/Contents/Resources"
BUILD_VPHONED=0
python3 "$SCRIPT_DIR/check_guest_api.py" /Users/kolar/github/vphone-cli/.build/t51-runtime-20261021/guest
mkdir -p "${RES}/guest-resources"
for name in vphoned vphoned-less vphoned.plist vphoned.entitlements.plist manifest.json; do
  cp -f "/Users/kolar/github/vphone-cli/.build/t51-runtime-20261021/guest/$name" "${RES}/guest-resources/$name"
done
cp -R /Users/kolar/github/vphone-cli/.build/t51-runtime-20261021/guest/api "${RES}/guest-resources/api"
cp -f /Users/kolar/github/vphone-cli/.build/t51-runtime-20261021/guest/cohort.json "${RES}/guest-resources/cohort.json"
# requirements.txt lets the app provision its own ~/.vphone/venv on first run
# (see VPhoneResources.pythonExecutable) — the app carries no venv itself.
cp -f requirements.txt "${RES}/requirements.txt"
cp -R dependencies "${RES}/dependencies"
# debs.list = extra-deb manifest (fetch_debs.sh reads $base/debs.list); README.md
# = the Tested-Environments table fw_prepare.sh reads to label Supported firmwares.
cp -f debs.list "${RES}/debs.list"
cp -f README.md "${RES}/README.md"
# vphone-amfidont helper (allows this .app through amfid). Kept in Resources —
# NOT MacOS — so bundle signing doesn't reject it as unsigned nested code; a
# Homebrew `binary` symlink exposes it on PATH.
cp -f scripts/vphone-amfidont "${RES}/vphone-amfidont"
chmod +x "${RES}/vphone-amfidont"
echo "  bundled: scripts/ (patchers+resources), tools/, .tools/bin/{trustcache,insert_dylib}, guest-resources/, requirements.txt, debs.list, README.md, vphone-amfidont"

# Rewrite and sign the complete host Mach-O closure before recording or sealing.
python3 "$SCRIPT_DIR/build_native_dependencies.py" "$BUNDLE"
python3 "$SCRIPT_DIR/record_build_dependencies.py" "$BUNDLE"

# Seal the final resource tree only after every runtime asset is staged.
echo "=== Signing ${BUNDLE} (final Resources) ==="
codesign --force --sign - "$BUNDLE"
python3 "$SCRIPT_DIR/check_bundle.py" "$BUNDLE"
echo "  resealed and verified OK"

echo ""
echo "=== Build complete ==="
echo "  binary : ${BINARY}"
echo "  bundle : ${BUNDLE}"
echo "  guest  : /Users/kolar/github/vphone-cli/.build/t51-runtime-20261021/guest/{vphoned,vphoned-less}"
echo ""
echo "Run: ${BINARY} --help"

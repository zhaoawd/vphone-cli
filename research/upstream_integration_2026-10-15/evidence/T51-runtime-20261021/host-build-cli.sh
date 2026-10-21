#!/bin/zsh
# build.sh — Build, sign, and bundle vphone-cli (+ cross-compile vphoned).
#
# This is the bootstrap step that a running binary cannot do for itself:
# it compiles the vphone-cli binary, signs it with the PV=3 entitlements,
# wraps it in the .app bundle used for GUI boot, and cross-compiles + signs
# the vphoned guest daemon. Everything else in the project is driven by the
# resulting `vphone-cli` binary — this script is the only build entrypoint.
#
# Usage:
#   ./scripts/build.sh              # build + sign + bundle + vphoned
#   ./scripts/build.sh --no-vphoned # reuse an existing signed daemon; still a complete app
set -euo pipefail

SCRIPT_DIR="/Users/kolar/github/vphone-cli/scripts"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

BINARY=".build/release/vphone-cli"
VM_BINARY=".build/release/vphone-vm"
BUNDLE=".build/t51-runtime-cli-20261021.app"
BUNDLE_BIN="${BUNDLE}/Contents/MacOS/vphone-cli"
INFO_PLIST="sources/Info.plist"
ENTITLEMENTS="sources/vphone.entitlements"
BUILD_INFO="sources/vphone-cli/VPhoneBuildInfo.swift"
GIT_HASH="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

BUILD_VPHONED=1
for arg in "$@"; do
  case "$arg" in
    --no-vphoned) BUILD_VPHONED=0 ;;
    -h|--help) echo "Usage: $0 [--no-vphoned]"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# --- Build + sign the binary ---
# Existing prepared vendor inputs preserved.
echo "=== Building vphone-cli (${GIT_HASH}) ==="
test -f "$BUILD_INFO"
swift build --disable-sandbox --cache-path "$PROJECT_ROOT/.build/test-cache" -c release --force-resolved-versions --product vphone-cli
swift build --disable-sandbox --cache-path "$PROJECT_ROOT/.build/test-cache" -c release --force-resolved-versions --product vphone-vm

echo "=== Signing with entitlements ==="
codesign --force --sign - "$BINARY"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$VM_BINARY"
echo "  signed OK → ${BINARY}"

# --- Bundle (.app used for GUI boot) ---
echo "=== Bundling ${BUNDLE} ==="
[[ ! -e "$BUNDLE" ]] || exit 2
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp -f "$BINARY" "$BUNDLE_BIN"
cp -f "$VM_BINARY" "${BUNDLE}/Contents/MacOS/vphone-vm"
cp -f "$INFO_PLIST" "${BUNDLE}/Contents/Info.plist"
cp -f "sources/AppIcon.icns" "${BUNDLE}/Contents/Resources/AppIcon.icns"
cp -f "$(command -v ldid)" "${BUNDLE}/Contents/MacOS/ldid"
codesign --force --sign - "${BUNDLE}/Contents/MacOS/ldid"
echo "  bundled → ${BUNDLE}"

# --- vphoned guest daemon (cross-compiled + signed for iOS arm64) ---
if [[ "$BUILD_VPHONED" -eq 1 ]]; then
  zsh "$SCRIPT_DIR/build_guest_payloads.sh"
fi

# --- Bundle the standalone runtime mini-repo into Contents/Resources ---
RES="${BUNDLE}/Contents/Resources"
echo "=== Bundling runtime assets → ${RES} ==="
mkdir -p "${RES}/scripts" "${RES}/tools" "${RES}/.tools/bin"
# Mirror scripts/ EXCEPT the make-coupled orchestrator, toolchain source, caches.
rsync -a \
  --exclude 'setup_machine.sh' \
  --exclude 'repos' \
  --exclude 'vphoned/vphoned' \
  --exclude '__pycache__' \
  --exclude '.git' \
  --exclude '.build' \
  scripts/ "${RES}/scripts/"
cp -f tools/apfs_snap_rename.py "${RES}/tools/apfs_snap_rename.py"
# Custom-built tools (bundled; not brew/pip). apfs_sealvolume is NOT bundled
# (it is extracted from the target IPSW at `fw prepare` time — Task 5).
for t in trustcache insert_dylib; do
  if [[ -x ".tools/bin/$t" ]]; then cp -f ".tools/bin/$t" "${RES}/.tools/bin/$t"
  else echo "Error: .tools/bin/$t missing — run ./scripts/setup_tools.sh first" >&2; exit 1; fi
done
# bsdtar delegates zstd/xz filters to executables when the OS codec is absent.
# Finder's launch environment must not depend on a package-manager PATH.
for compressor in zstd xz; do
  compressor_source="$(command -v "$compressor")"
  [[ -x "$compressor_source" ]] || { print -u2 "Missing build input: $compressor"; exit 1; }
  cp -f "$compressor_source" "${RES}/.tools/bin/$compressor"
  # Preserve the original relative library search during staging; the portable
  # dependency pass resolves this build input and removes the temporary rpath.
  install_name_tool -add_rpath "${compressor_source:h}/../lib" "${RES}/.tools/bin/$compressor"
done
python3 "$SCRIPT_DIR/check_guest_payloads.py" .build/guest
python3 "$SCRIPT_DIR/check_guest_api.py" .build/guest
mkdir -p "${RES}/guest-resources"
for name in vphoned vphoned-less vphoned.plist vphoned.entitlements.plist manifest.json; do
  cp -f ".build/guest/$name" "${RES}/guest-resources/$name"
done
cp -R .build/guest/api "${RES}/guest-resources/api"
cp -f .build/guest/cohort.json "${RES}/guest-resources/cohort.json"
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
echo "  guest  : .build/guest/{vphoned,vphoned-less}"
echo ""
echo "Run: ${BINARY} --help"

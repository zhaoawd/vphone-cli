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

SCRIPT_DIR="/Users/kolar/github/vphone-cli/scripts"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

TOOLCHAIN=".build/t51-runtime-cli-20261021.app"
APP=".build/t51-runtime-launchpad-r2-20261021.app"
HELPER="${APP}/Contents/Helpers/vphone-cli.app"
INFO_PLIST="sources/VPhoneLaunchpad-Info.plist"
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
swift build --disable-sandbox --cache-path "$PROJECT_ROOT/.build/test-cache" -c release --force-resolved-versions --product vphone-launchpad
swift build --disable-sandbox --cache-path "$PROJECT_ROOT/.build/test-cache" -c release --force-resolved-versions --product vphone-launchpad-launcher
BIN_DIR="$(swift build --disable-sandbox --cache-path "$PROJECT_ROOT/.build/test-cache" -c release --show-bin-path)"
BINARY="${BIN_DIR}/vphone-launchpad"
[[ -x "$BINARY" ]] || { print -u2 -- "Missing ${BINARY}"; exit 1; }
# SwiftPM may copy .xcstrings without compiling them. Compile the validated
# source catalogs explicitly; do not depend on the SwiftPM resource layout.
python3 "$SCRIPT_DIR/check_launchpad_strings.py"
LPROJ_DIR=".build/t51-runtime-localizations-r2-20261021"
[[ ! -e "$LPROJ_DIR" ]] || { print -u2 "candidate localizations already exist"; exit 2; }
mkdir -p "$LPROJ_DIR"
for catalog in Localizable InfoPlist; do
  xcrun xcstringstool compile "sources/VPhoneLaunchpad/${catalog}.xcstrings" \
    --output-directory "$LPROJ_DIR" --language en --language zh-Hans
done

# --- Assemble ---
echo "=== Assembling ${APP} ==="
[[ ! -e "$APP" ]] || { print -u2 "candidate app already exists"; exit 2; }
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/Helpers"
cp -f "$BINARY" "${APP}/Contents/MacOS/vphone-launchpad"
cp -f "${BIN_DIR}/vphone-launchpad-launcher" "${APP}/Contents/MacOS/vphone-launchpad-launcher"
codesign --force --sign - --identifier com.vphone.cli.launchpad.launcher "${APP}/Contents/MacOS/vphone-launchpad-launcher"
cp -f "$INFO_PLIST" "${APP}/Contents/Info.plist"
cp -f sources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
# Bundle.main and SwiftUI look in the app's Resources, so copy the compiled
# .lproj folders there before sealing the outer signature.
for lproj in "$LPROJ_DIR"/*.lproj(N); do
  cp -R "$lproj" "${APP}/Contents/Resources/"
done

python3 - "${APP}/Contents/Info.plist" <<'PYINFO'
import plistlib,sys
from pathlib import Path
p=Path(sys.argv[1]); info=plistlib.loads(p.read_bytes())
r=Path.cwd(); w=r/'.build/t51rt'
info['VPhoneLaunchpadDiagnosticsDirectory']=str(w/'ui-logs')
info['LSEnvironment']={'VPHONE_LIBRARY_ROOT':str(w/'lib'),'VPHONE_ROOT':str(w/'user-root'),'VPHONE_PYTHON':str(r/'.venv/bin/python3')}
p.write_bytes(plistlib.dumps(info))
PYINFO

# APFS clone: the 146 MB toolchain takes no extra space and keeps its
# signatures byte for byte. Other volumes get a full copy.
cp -cR "$TOOLCHAIN" "$HELPER"

# Stage only the outer host roots. The embedded CLI/VM bytes and signatures
# remain unchanged; remove absolute build-toolchain rpaths before final sealing.
python3 "$SCRIPT_DIR/build_native_dependencies.py" "$APP"

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

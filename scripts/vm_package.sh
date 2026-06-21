#!/bin/zsh
# vm_package.sh — Package a booted vphone VM + the host launcher into a single
# portable archive that boots on another Apple-Internal Mac WITHOUT recompiling.
#
# What goes in the package:
#   app/vphone-cli.app          the built+signed host launcher (no `swift build` on target)
#   app/vphone.entitlements     entitlements for re-signing on the target
#   vm/                         the VM state (Disk.img, nvram.bin, SEPStorage, config.plist,
#                               ROMs, SHSH, signed vphoned) — sparse-preserved
#   run.sh                      self-contained launcher (host checks → re-sign → amfidont → boot)
#   MANIFEST.txt / SHA256SUMS   provenance + integrity
#
# Build-time inputs (IPSW restore dir, .cfw_temp, ramdisk/cfw inputs) are excluded by
# default — they are NOT needed to boot an already-installed image. Add them with flags
# only if the target must also re-restore via DFU.
#
# Usage:
#   make vm_package                         # → dist/vphone-<name>-<date>.tar
#   make vm_package PKG_NAME=ios26-jb
#   zsh scripts/vm_package.sh --vm-dir vm --out dist/myimage.tar
#   zsh scripts/vm_package.sh --dir-only    # leave an unpacked directory (no tar)
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"

# --- Defaults ---
VM_DIR="${VM_DIR:-vm}"
BUNDLE="${BUNDLE:-.build/vphone-cli.app}"
ENTITLEMENTS="${ENTITLEMENTS:-sources/vphone.entitlements}"
OUT=""
PKG_NAME="${PKG_NAME:-}"
DIST_DIR="${DIST_DIR:-dist}"
DIR_ONLY=0
INCLUDE_RESTORE=0       # include *_Restore* IPSW dir (for DFU re-restore on target)
INCLUDE_RAMDISK=0       # include Ramdisk + cfw/ramdisk inputs (for patch/restore flows)
SKIP_DISK_CHECKSUM=0    # skip sha256 of Disk.img (faster, but SHA256SUMS won't cover the disk)

usage() {
    cat <<'EOF'
Usage: vm_package.sh [options]
  --vm-dir DIR        VM directory to package (default: vm)
  --bundle PATH       Built .app bundle (default: .build/vphone-cli.app)
  --out FILE          Output tar path (default: dist/vphone-<name>-<date>.tar)
  --name NAME         Friendly package name (default: VM dir's .vm_name or "vm")
  --dir-only          Produce an unpacked directory, skip the tar step
  --include-restore   Include the IPSW *_Restore* dir (large; only for DFU re-restore)
  --include-ramdisk   Include Ramdisk + cfw/ramdisk build inputs (only for patch flows)
  --no-disk-checksum  Skip SHA-256 of Disk.img (faster; SHA256SUMS then omits the disk)
  -h, --help          This help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm-dir)          VM_DIR="$2"; shift 2 ;;
        --bundle)          BUNDLE="$2"; shift 2 ;;
        --out)             OUT="$2"; shift 2 ;;
        --name)            PKG_NAME="$2"; shift 2 ;;
        --dir-only)        DIR_ONLY=1; shift ;;
        --include-restore) INCLUDE_RESTORE=1; shift ;;
        --include-ramdisk) INCLUDE_RAMDISK=1; shift ;;
        --no-disk-checksum) SKIP_DISK_CHECKSUM=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

cd "$PROJECT_ROOT"

# --- Validate inputs ---
[[ -d "$VM_DIR" ]]               || { echo "ERROR: VM directory not found: $VM_DIR" >&2; exit 1; }
[[ -f "$VM_DIR/config.plist" ]]  || { echo "ERROR: $VM_DIR/config.plist missing — not a valid VM" >&2; exit 1; }
# Disk path comes from the manifest, not a hardcoded name (custom diskImage is allowed).
DISK_NAME="$(/usr/libexec/PlistBuddy -c 'Print :diskImage' "$VM_DIR/config.plist" 2>/dev/null || true)"
[[ -n "$DISK_NAME" ]]            || { echo "ERROR: $VM_DIR/config.plist has no diskImage key" >&2; exit 1; }
[[ -f "$VM_DIR/$DISK_NAME" ]]    || { echo "ERROR: $VM_DIR/$DISK_NAME (manifest diskImage) missing" >&2; exit 1; }
if [[ ! -x "$BUNDLE/Contents/MacOS/vphone-cli" ]]; then
    echo "ERROR: launcher bundle not found: $BUNDLE" >&2
    echo "  Build it first:  make bundle" >&2
    exit 1
fi
[[ -f "$ENTITLEMENTS" ]]         || { echo "ERROR: entitlements not found: $ENTITLEMENTS" >&2; exit 1; }

# --- Validate boot-critical files named by the manifest ---
# config.plist resolves these ROM/SEP/NVRAM/disk paths before the VM starts, so a
# package missing any of them is non-bootable. Derive the list from the manifest
# (not a hardcoded set) and refuse to package if any are absent.
MANIFEST_FILES=()
for key in diskImage nvramStorage sepStorage romImages:avpBooter romImages:avpSEPBooter; do
    val="$(/usr/libexec/PlistBuddy -c "Print :$key" "$VM_DIR/config.plist" 2>/dev/null || true)"
    [[ -n "$val" ]] && MANIFEST_FILES+=("$val")
done
missing_boot=()
for f in "${MANIFEST_FILES[@]}"; do [[ -e "$VM_DIR/$f" ]] || missing_boot+=("$f"); done
if (( ${#missing_boot[@]} )); then
    echo "ERROR: config.plist references files missing from ${VM_DIR} — VM is not bootable:" >&2
    printf '  %s\n' "${missing_boot[@]}" >&2
    exit 1
fi

# --- Refuse to package a live VM ---
# The reliable signal is "is the manifest's disk image held open by a process?" —
# this catches `make boot` (which runs `vphone-cli --config ./config.plist` from
# inside vm/, so the VM dir never appears in the argv) and any other launcher path.
DISK_ABS="${VM_DIR:A}/${DISK_NAME}"
if command -v lsof >/dev/null 2>&1; then
    if lsof -- "$DISK_ABS" >/dev/null 2>&1; then
        echo "ERROR: ${DISK_ABS} is open in another process — the VM is running." >&2
        echo "  Shut the VM down first — packaging a live disk yields a corrupt snapshot." >&2
        exit 1
    fi
elif [[ -S "$VM_DIR/vphone.sock" ]]; then
    # No lsof to confirm; a live control socket is a strong hint. Stale sockets
    # are possible after a crash, so this fallback only triggers without lsof.
    echo "ERROR: live control socket present at ${VM_DIR}/vphone.sock — VM may be running." >&2
    echo "  Shut the VM down first (or remove a stale socket), then re-run." >&2
    exit 1
fi

# --- Resolve names / paths ---
if [[ -z "$PKG_NAME" ]]; then
    if [[ -f "$VM_DIR/.vm_name" ]]; then PKG_NAME="$(cat "$VM_DIR/.vm_name")"; else PKG_NAME="vm"; fi
fi
STAMP="$(date +%Y%m%d-%H%M%S)"
GIT_HASH="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
[[ -n "$OUT" ]] || OUT="${DIST_DIR}/vphone-${PKG_NAME}-${STAMP}.tar"
STAGE="${DIST_DIR}/.stage-${PKG_NAME}-${STAMP}"
PKG_TOP="vphone-${PKG_NAME}"           # top-level dir name inside the archive
STAGE_PKG="${STAGE}/${PKG_TOP}"

echo "=== vphone vm_package ==="
echo "VM dir      : ${VM_DIR}/"
echo "Launcher    : ${BUNDLE}"
echo "Name        : ${PKG_NAME}"
echo "Commit      : ${GIT_HASH}"
echo "Output      : ${OUT}"
echo "Include IPSW: $([[ $INCLUDE_RESTORE == 1 ]] && echo yes || echo no)"
echo "Include rdsk: $([[ $INCLUDE_RAMDISK == 1 ]] && echo yes || echo no)"
echo ""

mkdir -p "$STAGE_PKG/app" "$STAGE_PKG/vm" "$DIST_DIR"
trap 'rm -rf "$STAGE"' EXIT

# --- Stage launcher (sparse-irrelevant, small) ---
echo "[1/5] Staging launcher bundle"
rsync -a "$BUNDLE/" "$STAGE_PKG/app/vphone-cli.app/"
cp -f "$ENTITLEMENTS" "$STAGE_PKG/app/vphone.entitlements"

# --- Stage VM state (sparse-preserved) ---
echo "[2/5] Staging VM state (rsync --sparse)"
EXCLUDES=(
    --exclude 'vphone.sock'            # live unix socket — cannot/should not be copied
    --exclude '.DS_Store'
    --exclude '.gitkeep'
    --exclude '.cfw_temp/'             # CFW build scratch
)
if [[ $INCLUDE_RESTORE != 1 ]]; then
    EXCLUDES+=(--exclude '*_Restore*/')   # IPSW restore tree (~10G), only for DFU re-restore
fi
if [[ $INCLUDE_RAMDISK != 1 ]]; then
    EXCLUDES+=(--exclude 'Ramdisk/' --exclude 'ramdisk_input/' \
               --exclude 'cfw_input/' --exclude 'cfw_jb_input/')
fi
rsync -aHS "${EXCLUDES[@]}" "$VM_DIR/" "$STAGE_PKG/vm/"

# --- Emit run.sh (target-side launcher) ---
echo "[3/5] Writing run.sh"
cat > "$STAGE_PKG/run.sh" <<'RUNEOF'
#!/bin/zsh
# run.sh — Boot this packaged vphone image on an Apple-Internal Mac.
#
# Prerequisites on the target host (one-time, see README.txt):
#   - macOS 15+ on real Apple Silicon (NOT a nested VM)
#   - SIP disabled                          (csrutil disable, in Recovery)
#   - allow-research-guests enabled         (csrutil allow-research-guests enable, in Recovery)
#   - amfidont installed                    (xcrun python3 -m pip install -U amfidont)
#
# Usage:
#   ./run.sh                 boot the image
#   ./run.sh --dfu           boot in DFU mode
#   ./run.sh --skip-amfidont skip the amfidont allowlist step (already running it yourself)
#   ./run.sh --skip-sign     do not re-sign the launcher (already trusted on this host)
#   ./run.sh --check         run host preflight only, do not boot
set -euo pipefail

PKG_DIR="${0:A:h}"
APP="${PKG_DIR}/app/vphone-cli.app"
APP_BIN="${APP}/Contents/MacOS/vphone-cli"
ENT="${PKG_DIR}/app/vphone.entitlements"
VM_DIR="${PKG_DIR}/vm"

DFU=0 SKIP_AMFIDONT=0 SKIP_SIGN=0 CHECK_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dfu)           DFU=1; shift ;;
    --skip-amfidont) SKIP_AMFIDONT=1; shift ;;
    --skip-sign)     SKIP_SIGN=1; shift ;;
    --check)         CHECK_ONLY=1; shift ;;
    -h|--help)       sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -x "$APP_BIN" ]] || { echo "ERROR: launcher missing: $APP_BIN" >&2; exit 1; }
[[ -f "$VM_DIR/config.plist" ]] || { echo "ERROR: $VM_DIR/config.plist missing" >&2; exit 1; }

fail=0
note() { print -r -- "  $1"; }
echo "=== vphone host preflight ==="

# macOS version
OSVER="$(sw_vers -productVersion 2>/dev/null || echo 0)"
note "macOS: $OSVER"
[[ "${OSVER%%.*}" -ge 15 ]] 2>/dev/null || { note "  ✗ needs macOS 15+"; fail=1; }

# Not a nested VM
HVP="$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)"
MODEL="$(sysctl -n hw.model 2>/dev/null || echo '')"
if [[ "$HVP" == "1" || "$MODEL" == "VirtualMac"* ]]; then
  note "✗ running inside a VM ($MODEL) — PV=3 guest boot unavailable here"; fail=1
else
  note "host hardware: $MODEL (bare metal ✓)"
fi

# SIP — fully-enabled SIP cannot work; "disabled" or "Custom Configuration" are fine.
SIP_LINE="$(csrutil status 2>/dev/null | head -1 || echo unknown)"
note "SIP: ${SIP_LINE#System Integrity Protection }"
if echo "$SIP_LINE" | grep -qi 'status: enabled'; then
  note "  ✗ SIP is fully enabled — disable it in Recovery: csrutil disable"; fail=1
fi

# Research guests — required to boot a research (PV=3) guest
RG="$(csrutil allow-research-guests status </dev/null 2>/dev/null | grep -o 'status:.*' || echo 'unknown')"
note "allow-research-guests: $RG"
if ! echo "$RG" | grep -qi 'enabled'; then
  note "  ✗ not enabled — (Recovery) csrutil allow-research-guests enable"; fail=1
fi

# amfidont must be locatable now (it applies the entitlement allowlist before boot).
# Resolve it during preflight so --check fails when it is missing instead of at boot.
AMFI=""
if (( ! SKIP_AMFIDONT )); then
  AMFI="${AMFIDONT:-$(command -v amfidont 2>/dev/null || true)}"
  if [[ -z "$AMFI" ]]; then
    ubase="$(xcrun python3 -m site --user-base 2>/dev/null || true)"
    [[ -n "$ubase" && -x "$ubase/bin/amfidont" ]] && AMFI="$ubase/bin/amfidont"
  fi
  if [[ -z "$AMFI" ]]; then
    note "✗ amfidont not found — xcrun python3 -m pip install -U amfidont (or pass --skip-amfidont)"; fail=1
  elif [[ ! -x "$AMFI" ]]; then
    note "✗ amfidont not executable: $AMFI (check \$AMFIDONT)"; fail=1
  else
    note "amfidont: $AMFI"
  fi
fi

if (( fail )); then
  echo ""
  echo "Preflight failed — see README.txt for one-time host setup." >&2
  exit 1
fi
(( CHECK_ONLY )) && { echo "Preflight OK."; exit 0; }

# Re-sign launcher with the private entitlements (ad-hoc; required for PV=3)
if (( ! SKIP_SIGN )); then
  echo "=== re-signing launcher ==="
  codesign --force --sign - --entitlements "$ENT" "$APP_BIN"
  [[ -x "$APP/Contents/MacOS/ldid" ]] && codesign --force --sign - "$APP/Contents/MacOS/ldid" 2>/dev/null || true
fi

# amfidont allowlist so the signed private entitlements are honored.
# $AMFI was already resolved (and validated) during preflight.
if (( ! SKIP_AMFIDONT )); then
  echo "=== amfidont allowlist ==="
  CDHASH="$( { codesign -d -vvvv "$APP_BIN" 2>&1 || true; } | awk -F= '/^CDHash=/{print $2; exit}')"
  args=(daemon --path "$PKG_DIR")
  # Also allowlist the URL-encoded form so a package unpacked under a path with
  # spaces / escaped characters still matches (mirrors start_amfidont_for_vphone.sh).
  ENC_DIR="$(printf %s "$PKG_DIR" | xcrun python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read(),safe="/"))' 2>/dev/null || true)"
  [[ -n "$ENC_DIR" && "$ENC_DIR" != "$PKG_DIR" ]] && args+=(--path "$ENC_DIR")
  [[ -n "$CDHASH" ]] && args+=(--cdhash "$CDHASH")
  args+=(--spoof-apple)
  # Prime sudo with a normal prompt, then run capturing output so a real failure
  # (wrong password, bad args, daemon error) fails closed instead of booting blind.
  sudo -v || { echo "ERROR: sudo authentication failed — cannot start amfidont." >&2; exit 1; }
  if ! out="$(sudo "$AMFI" "${args[@]}" 2>&1)"; then
    echo "ERROR: amfidont failed to start:" >&2
    [[ -n "$out" ]] && print -r -- "$out" >&2
    echo "Fix the above, or pass --skip-amfidont if your host already allows these entitlements." >&2
    exit 1
  fi
  echo "  amfidont started for: $PKG_DIR"
fi

# Boot
echo "=== boot ==="
cd "$VM_DIR"
if (( DFU )); then
  exec "$APP_BIN" --config ./config.plist --dfu
else
  exec "$APP_BIN" --config ./config.plist
fi
RUNEOF
chmod +x "$STAGE_PKG/run.sh"

# --- README + manifest ---
cat > "$STAGE_PKG/README.txt" <<EOF
vphone packaged image — ${PKG_NAME}
Built from commit ${GIT_HASH} on $(date '+%Y-%m-%d %H:%M:%S').

WHAT THIS IS
  A self-contained, already-booted virtual iPhone image plus the host launcher.
  No source build needed on the target — run.sh re-signs and boots it.

ONE-TIME HOST SETUP (target Mac)
  The target MUST be a bare-metal, Apple-Internal / research-enabled Mac. A retail
  Mac cannot boot the vresearch101 platform even with these files.
    1. Disable SIP:            (Recovery) csrutil disable
    2. Allow research guests:  (Recovery) csrutil allow-research-guests enable
    3. Install amfidont:       xcrun python3 -m pip install -U amfidont
  Reboot back into macOS, then:

RUN
    ./run.sh           # preflight → re-sign → amfidont → boot
    ./run.sh --check   # preflight only
    ./run.sh --dfu     # boot in DFU mode

CONTENTS
  app/vphone-cli.app        host launcher (signed on target by run.sh)
  app/vphone.entitlements   private entitlements (PV=3 virtualization)
  vm/                       VM state (Disk.img, nvram.bin, SEPStorage, config.plist, ROMs)
  run.sh                    launcher
  SHA256SUMS                integrity (verify: cd ${PKG_TOP} && shasum -c SHA256SUMS)

NOTES
  - IPSW restore tree / build inputs are excluded; this image boots as-is but cannot
    re-restore via DFU unless packaged with --include-restore.
  - Copy this directory with sparse preservation (tar -x -S, or rsync -aS); a naive
    copy inflates Disk.img to its full logical size.
EOF

# --- Manifest ---
{
    echo "package    : ${PKG_TOP}"
    echo "name       : ${PKG_NAME}"
    echo "commit     : ${GIT_HASH}"
    echo "built_at   : $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "built_on   : $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))"
    echo "vm_source  : ${VM_DIR}"
    echo "include_restore: ${INCLUDE_RESTORE}"
    echo "include_ramdisk: ${INCLUDE_RAMDISK}"
    echo "--- config.plist ---"
    /usr/libexec/PlistBuddy -c Print "$VM_DIR/config.plist" 2>/dev/null \
        | grep -vi 'machineIdentifier' || true
} > "$STAGE_PKG/MANIFEST.txt"

# --- Checksums ---
echo "[4/5] Computing SHA256SUMS$( (( SKIP_DISK_CHECKSUM )) && echo ' (Disk.img skipped)' || echo ' (incl. Disk.img — may take a while)')"
(
    cd "$STAGE_PKG"
    DISK_NAME="$(/usr/libexec/PlistBuddy -c 'Print :diskImage' vm/config.plist 2>/dev/null || echo Disk.img)"
    # Mandatory: launcher essentials + every manifest-named boot file (already
    # existence-validated above). A vanished or unhashable input is an error,
    # never silently omitted.
    mandatory=( app/vphone-cli.app/Contents/MacOS/vphone-cli app/vphone.entitlements run.sh vm/config.plist )
    for f in "${MANIFEST_FILES[@]}"; do
        [[ "$f" == "$DISK_NAME" ]] && (( SKIP_DISK_CHECKSUM )) && continue
        mandatory+=("vm/$f")
    done
    missing=()
    for f in "${mandatory[@]}"; do
        if [[ -d "$f" ]]; then
            continue   # validated to exist already; shasum can't hash a directory
        elif [[ ! -f "$f" ]]; then
            missing+=("$f")
        fi
    done
    if (( ${#missing[@]} )); then
        echo "ERROR: required files missing from staged package, cannot checksum:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        exit 1
    fi
    files=()
    for f in "${mandatory[@]}"; do [[ -f "$f" ]] && files+=("$f"); done   # drop dirs
    # Optional extras: signed-daemon marker + SHSH blobs.
    [[ -f vm/.vphoned.signed ]] && files+=(vm/.vphoned.signed)
    for f in vm/*.shsh(N); do files+=("$f"); done   # (N) = null glob, no abort if none
    shasum -a 256 "${files[@]}" > SHA256SUMS
)

# --- Package ---
if (( DIR_ONLY )); then
    FINAL="${OUT%.tar}"
    rm -rf "$FINAL"
    mv "$STAGE_PKG" "$FINAL"
    echo "[5/5] Directory package ready"
    echo ""
    echo "  → ${FINAL}/   ($(du -sh "$FINAL" 2>/dev/null | cut -f1) on disk)"
    echo "  Copy with sparse preservation:  rsync -aS '${FINAL}/' dest/"
else
    echo "[5/5] Creating sparse tar (this can take a while for large disks)"
    # bsdtar -S preserves sparse holes on both create and extract.
    tar -c -S -C "$STAGE" -f "$OUT" "$PKG_TOP"
    echo ""
    echo "  → ${OUT}   ($(du -sh "$OUT" 2>/dev/null | cut -f1) on disk)"
    echo "  Transfer this file, then on the target:"
    echo "    tar -x -S -f $(basename "$OUT")   # -S restores sparse holes"
    echo "    cd ${PKG_TOP} && ./run.sh"
fi
echo ""
echo "Done."

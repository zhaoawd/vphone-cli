#!/bin/zsh
# cfw_install_host.sh — CFW install by host-mounting the VM's Disk.img.
#
# Attaches the VM's Disk.img on the host and hands the container to the variant
# installer (cfw_install*.sh), which mounts the APFS volumes and places every
# CFW file directly. Then flips the boot snapshot offline
# (tools/apfs_snap_rename.py) so the VM boots the live volume.
#
# Prereqs: VM restored (make restore) and powered off; host has gnu-tar, ipsw,
# aea, ldid, zstd, project venv (make setup_tools). SIP disabled (project
# baseline); NO authenticated-root/ARV change needed.
#
# Usage: cfw_install_host.sh [--variant regular|dev|jb|exp] [vm_dir]
# Runs as root (mount_apfs/chown/cp to owners-honored mounts); re-execs under
# sudo automatically (honors SUDO_ASKPASS for non-interactive use).
set -euo pipefail
SCRIPT_DIR="${0:a:h}"
PROJ="${SCRIPT_DIR:h}"

VARIANT=exp
VM_DIR="$PROJ/vm"
while (( $# )); do
  case "$1" in
    --variant) VARIANT="$2"; shift 2 ;;
    *)         VM_DIR="$1";  shift ;;
  esac
done

case "$VARIANT" in
  regular) INSTALLER=cfw_install.sh ;;
  dev)     INSTALLER=cfw_install_dev.sh ;;
  jb)      INSTALLER=cfw_install_jb.sh ;;
  exp)     INSTALLER=cfw_install_exp.sh ;;
  *) echo "[-] unknown variant: $VARIANT (regular|dev|jb|exp)" >&2; exit 1 ;;
esac

# Re-exec as root; owners-honored mounts + chown/cp require it.
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo ${SUDO_ASKPASS:+-A} -E /bin/zsh "$0" --variant "$VARIANT" "$VM_DIR"
fi
unset SUDO_ASKPASS   # already root: host_hdiutil/pre-step use plain sudo/hdiutil

VM_DIR="$(cd "$VM_DIR" && pwd -P)"
IMG="$VM_DIR/Disk.img"
[[ -f "$IMG" ]] || { echo "[-] no Disk.img at $IMG" >&2; exit 1; }

# Host-side install toolchain (gnu-tar/ipsw/aea/ldid/zstd + venv python).
# VPHONE_PYTHON overrides the venv python (e.g. a bundled .app has no .venv);
# unset falls back to the repo venv, unchanged from before.
if [[ -n "${VPHONE_PYTHON:-}" ]]; then
  P="$PROJ/.tools/bin:$(dirname "$VPHONE_PYTHON"):/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
else
  P="$PROJ/.tools/bin:$PROJ/.venv/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
fi
export PATH="$P"
PY="${VPHONE_PYTHON:-$PROJ/.venv/bin/python3}"

if lsof "$IMG" >/dev/null 2>&1; then
  echo "[-] $IMG is in use — stop the VM first." >&2; exit 1
fi

# One private directory per invocation, including temporary Cryptex mounts.
# Keep it beneath the VM directory so installer path checks remain applicable.
CFW_HOST_MNT=$(mktemp -d "$VM_DIR/.cfw_mount.XXXXXXXX")
export CFW_HOST_MNT
BASEDISK=""

cleanup() {
  local failed=0 line dev mnt
  # hdiutil may report an attached disk and then fail or receive a signal.
  # Recover that device from invocation-local output even before discovery.
  if [[ -z "$BASEDISK" && -f "$CFW_HOST_MNT/attach.log" ]]; then
    BASEDISK=$(awk 'NR == 1 { print $1; exit }' "$CFW_HOST_MNT/attach.log")
    [[ "$BASEDISK" == /dev/disk<-> ]] || BASEDISK=""
  fi
  # Query actual mounts; never unmount a shared or previous invocation's path.
  local mounts
  mounts=$(/sbin/mount) || return 1
  for line in "${(@f)mounts}"; do
    dev="${line%% on *}"
    mnt="${line#* on }"
    mnt="${mnt% \(*}"
    [[ "$mnt" == "$CFW_HOST_MNT/"* ]] || continue
    print -r -- "[*] cleanup mount: $dev -> $mnt"
    case "$mnt" in
      "$CFW_HOST_MNT"/mnt_sysos*)
        hdiutil detach "$mnt" || failed=1 ;;
      "$CFW_HOST_MNT"/mnt_appos)
        hdiutil detach "$mnt" || failed=1 ;;
      *) umount "$mnt" || failed=1 ;;
    esac
  done
  if [[ -n "$BASEDISK" ]]; then
    if hdiutil detach "$BASEDISK" || diskutil eject "$BASEDISK"; then
      BASEDISK=""
      rm -f "$CFW_HOST_MNT/attach.log" || failed=1
    else
      failed=1
    fi
  fi
  if (( failed == 0 )); then
    # Only empty mountpoint directories are removed. Never recurse into a
    # filesystem that failed to unmount or delete unrelated installer data.
    rm -f "$CFW_HOST_MNT/attach.log" || failed=1
    local dir
    for dir in "$CFW_HOST_MNT"/*(N/); do
      rmdir "$dir" || failed=1
    done
    (( failed )) || rmdir "$CFW_HOST_MNT" || failed=1
  fi
  (( failed == 0 )) || print -u2 -- "[-] cleanup incomplete; retained $CFW_HOST_MNT"
  return "$failed"
}
finish() {
  local original=$?
  trap - EXIT INT TERM HUP
  if ! cleanup; then
    (( original != 0 )) || original=1
  fi
  exit "$original"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

echo "[*] host-mode CFW install: variant=$VARIANT vm=$VM_DIR mounts=$CFW_HOST_MNT"
hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" > "$CFW_HOST_MNT/attach.log"
BASEDISK=$(awk 'NR == 1 { print $1; exit }' "$CFW_HOST_MNT/attach.log")
[[ "$BASEDISK" == /dev/disk<-> ]] || { echo "[-] invalid attached disk: $BASEDISK" >&2; BASEDISK=""; exit 1; }
echo "[*] attached image: $BASEDISK"
CONT=$(diskutil info -plist "${BASEDISK}s1" | /usr/bin/plutil -extract APFSContainerReference raw -o - - 2>/dev/null || true)
SYS=$(diskutil apfs list "$CONT" 2>/dev/null | awk '/APFS Volume Disk \(Role\):/{for(i=1;i<=NF;i++) if($i ~ /^disk[0-9]+s[0-9]+$/) dev=$i} /Name:.*System \(Case-sensitive\)/{print dev; exit}')
[[ -n "$CONT" && -n "$SYS" ]] || { echo "[-] System volume not found in $IMG" >&2; exit 1; }
echo "[*] attached: container=$CONT system=$SYS"

echo "[*] running $INSTALLER (files placed on host mounts)..."
# via env: an expansion-produced ${VAR:+NAME=val} isn't parsed as a shell assignment.
( cd "$VM_DIR" && env CFW_HOST_CONTAINER="$CONT" _VPHONE_PATH="$P" \
    ${SPOOF_BUILD:+SPOOF_BUILD="$SPOOF_BUILD"} \
    ${FORCE_DSC_MAXSLIDE:+FORCE_DSC_MAXSLIDE="$FORCE_DSC_MAXSLIDE"} \
    ${VPHONE_FRIDA:+VPHONE_FRIDA="$VPHONE_FRIDA"} \
    zsh "$SCRIPT_DIR/$INSTALLER" . )

cleanup
trap - EXIT INT TERM HUP

echo "[*] flipping boot snapshot offline (com.apple.os.update -> live volume)..."
"$PY" "$PROJ/tools/apfs_snap_rename.py" "$IMG"

# Drop the extracted CFW input dirs (source .tar.zst re-extracts). VPHONE_KEEP_ARTIFACTS opts out.
if [[ -z "${VPHONE_KEEP_ARTIFACTS:-}" ]]; then
  rm -rf "${VM_DIR:?}/cfw_input" "${VM_DIR:?}/cfw_jb_input"
fi

# The whole install ran as root (owners-honored mounts / chown / cp). Hand the
# host-side artifacts it created (vm/.vphoned.signed, vm/.cfw_temp, extracted
# cfw_input/cfw_jb_input, the vphoned build) back to the invoking user, so the
# subsequent user-run steps (make boot / setup_machine first boot, which rewrite
# vm/.vphoned.signed) don't hit "Permission denied".
if [[ -n "${SUDO_USER:-}" ]]; then
  chown -R "$SUDO_USER" "$VM_DIR" 2>/dev/null || true
  [[ -e "$PROJ/scripts/vphoned/vphoned" ]] && chown "$SUDO_USER" "$PROJ/scripts/vphoned/vphoned" 2>/dev/null || true
  echo "[*] restored ownership of host-side artifacts to $SUDO_USER"
fi

echo "[+] host-mode CFW install complete. Boot with: make boot"

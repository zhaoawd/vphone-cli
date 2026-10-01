#!/bin/zsh
# cfw_install_host.sh — CFW install by host-mounting the VM's Disk.img.
#
# Stages a copy of the VM's Disk.img (APFS clone, else a SHA-256-verified sparse
# full copy, else refusal; scripts/cfw_disk_txn.py), attaches that copy on the
# host and hands the container to the variant installer (cfw_install*.sh),
# which mounts the APFS volumes and places every CFW file directly. Then flips
# the boot snapshot offline on the copy (tools/apfs_snap_rename.py) so the VM
# boots the live volume, and publishes the copy over Disk.img with
# renamex_np(RENAME_SWAP) (two RENAME_EXCL renames where the volume rejects
# RENAME_SWAP, as HFS+ does). The previous disk is kept in .cfw-history/<id>/.
# Any failure before publication leaves the original Disk.img unmodified.
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
[[ -f "$IMG" && ! -L "$IMG" ]] || { echo "[-] no Disk.img (regular file) at $IMG" >&2; exit 1; }

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

# Acquire after sudo, which may close inherited descriptors. The re-executed
# operation tree must prove possession of the directory descriptor.
if ! "$PY" "$SCRIPT_DIR/vm_lock.py" --check-inherited "$VM_DIR"; then
  [[ -z "${VPHONE_CFW_LOCK_REEXEC:-}" ]] || { echo "[-] inherited CFW lock validation failed" >&2; exit 1; }
  export VPHONE_CFW_LOCK_REEXEC=1
  exec "$PY" "$SCRIPT_DIR/vm_lock.py" "$VM_DIR" cfw -- /bin/zsh "$0" --variant "$VARIANT" "$VM_DIR"
fi

# FORCE_DSC_MAXSLIDE (non-27 maxSlide opt-in) is removed (T13a, upstream d930e50).
# Report it for every variant and keep it from the installers; patch-dsc-maxslide
# decides from the cache header on a 27.* base.
if [[ -n "${FORCE_DSC_MAXSLIDE:-}" ]]; then
  echo "[!] FORCE_DSC_MAXSLIDE has been removed and is ignored (value: $FORCE_DSC_MAXSLIDE)." >&2
  echo "    On an iOS 27.* base, patch-dsc-maxslide zeroes maxSlide when the cache overflows the kernel shared region; other bases keep their slide." >&2
  unset FORCE_DSC_MAXSLIDE
fi

# A previous invocation may have left mounted volumes. Do not change owners or
# begin another installation until those volumes have been inspected/unmounted.
assert_no_vm_mounts() {
  local line mnt mounts
  mounts=$(/sbin/mount) || return 1
  for line in "${(@f)mounts}"; do
    mnt="${line#* on }"; mnt="${mnt% \(*}"
    if [[ "$mnt" == "$VM_DIR/"* ]]; then
      print -u2 -- "[-] mounted filesystem beneath VM directory: $mnt; unmount it before retrying CFW"
      return 1
    fi
  done
}
assert_no_vm_mounts

# Only root's and the invoker's entries change owner; see the ownership note
# near the end of this script.
restore_invoker_ownership() {
  local target="$1"
  find -x "$target" \( -type d ! -user 0 ! -user "$SUDO_UID" -prune \) -o \
    \( \( -type d -o \( -type f -links 1 \) \) \( -user 0 -o -user "$SUDO_UID" \) \
       -exec chown -h "$SUDO_UID" {} + \)
}

# T15 disk transaction. This process holds a read-only descriptor on the
# original Disk.img for its whole run; identity checks compare it with the
# name, and the busy check excludes this process and the helper only. The
# original is never opened for writing: CFW goes to the staged copy, which is
# published by an exchange rename after every step succeeded. Long-running
# children (hdiutil attach, installers) do not inherit the descriptor.
exec {DISK_FD}<"$IMG"
CFW_DISK_WORK=$(mktemp -d "$VM_DIR/.cfw_disk.XXXXXXXX")
CFW_STAGED_IMG=""
TXN_STATE=none
txn() {
  local command="$1"; shift
  "$PY" "$SCRIPT_DIR/cfw_disk_txn.py" "$command" --fd "$DISK_FD" --owner-pid $$ "$@" "$VM_DIR" "$CFW_DISK_WORK"
}
# Record an unpublished run: remove the copy (kept when its mounts could not be
# released), verify the original, archive the record in .cfw-history.
txn_abort() {
  local code="$1" retain="$2" record
  [[ "$TXN_STATE" != published && -d "$CFW_DISK_WORK" ]] || return 0
  record=$(txn finish --exit-code "$code" ${retain:+--retain-staged}) || return 1
  if [[ -n "${SUDO_USER:-}" && "${SUDO_UID:-}" =~ '^[0-9]+$' ]]; then
    [[ "$record" == "$VM_DIR/.cfw-history/"* ]] && record="$VM_DIR/.cfw-history"
    [[ -d "$record" && ! -L "$record" ]] && restore_invoker_ownership "$record"
  fi
  return 0
}

# One private directory per invocation, including temporary Cryptex mounts.
# Keep it beneath the VM directory so installer path checks remain applicable.
CFW_HOST_MNT=$(mktemp -d "$VM_DIR/.cfw_mount.XXXXXXXX")
export CFW_HOST_MNT
BASEDISK=""
CLEANUP_DONE=0
CLEANUP_FAILED=0

attached_disk() {
  "$PY" -c 'import plistlib,re,sys
with open(sys.argv[1], "rb") as stream:
    info = plistlib.load(stream)
entities = info["system-entities"]
bases = {entry.get("dev-entry", "") for entry in entities
         if re.fullmatch(r"/dev/disk[0-9]+", entry.get("dev-entry", ""))}
# APFS also lists a synthesized container as /dev/diskN. Prefer the
# device carrying the partition map, not the synthesized container.
physical = {entry.get("dev-entry") for entry in entities
            if entry.get("content-hint") in ("GUID_partition_scheme", "FDisk_partition_scheme", "Apple_partition_scheme")}
if physical: bases &= physical
if len(bases) != 1: raise ValueError("no unique base disk in attach output")
print(bases.pop())' "$CFW_HOST_MNT/attach.log"
}

unmount_volume() {
  local attempt
  for attempt in 1 2 3; do
    "$@" && return 0
    (( attempt == 3 )) || sleep 1
  done
  return 1
}

cleanup() {
  local failed=0 line dev mnt
  # hdiutil may report an attached disk and then fail or receive a signal.
  # Recover that device from invocation-local output even before discovery.
  if [[ -z "$BASEDISK" && -f "$CFW_HOST_MNT/attach.log" ]]; then
    BASEDISK=$(trap - EXIT INT TERM HUP; attached_disk) || true
    [[ "$BASEDISK" == /dev/disk<-> ]] || { BASEDISK=""; failed=1; }
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
        unmount_volume hdiutil detach "$mnt" || failed=1 ;;
      "$CFW_HOST_MNT"/mnt_appos)
        unmount_volume hdiutil detach "$mnt" || failed=1 ;;
      *) unmount_volume umount "$mnt" || failed=1 ;;
    esac
  done
  if (( failed == 0 )) && [[ -n "$BASEDISK" ]]; then
    if hdiutil detach "$BASEDISK" || diskutil eject "$BASEDISK"; then
      BASEDISK=""
      rm -f "$CFW_HOST_MNT/attach.log" || failed=1
    else
      failed=1
    fi
  fi
  (( failed == 0 )) || { print -u2 -- "[-] cleanup incomplete; retained $CFW_HOST_MNT"; return 1; }
  # Every mount beneath the directory is released and the image is detached,
  # which is all the offline snapshot flip requires. Directory removal is
  # best-effort: only empty mountpoint directories are removed, and stray files
  # keep the directory in place with a warning rather than failing the install.
  rm -f "$CFW_HOST_MNT/attach.log" || true
  local dir retained=0
  for dir in "$CFW_HOST_MNT"/*(N/); do
    rmdir "$dir" 2>/dev/null || retained=1
  done
  (( retained )) || rmdir "$CFW_HOST_MNT" 2>/dev/null || retained=1
  (( retained == 0 )) || print -u2 -- "[!] mounts released; unexpected files retained in $CFW_HOST_MNT (inspect and remove manually)"
  return 0
}
finish() {
  local original=$? retain=""
  trap - EXIT INT TERM HUP
  if (( ! CLEANUP_DONE )) && ! cleanup; then
    (( original != 0 )) || original=1
    CLEANUP_FAILED=1
  fi
  (( CLEANUP_FAILED )) && retain=1
  if ! txn_abort "$original" "$retain"; then
    (( original != 0 )) || original=1
  fi
  exit "$original"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

echo "[*] host-mode CFW install: variant=$VARIANT vm=$VM_DIR mounts=$CFW_HOST_MNT staging=$CFW_DISK_WORK"
# zsh does not run the EXIT trap when ERR_EXIT fires inside a function, so
# every failing txn call exits explicitly at top level.
CFW_STAGED_IMG=$(txn stage) || exit $?
TXN_STATE=staged
echo "[*] staged copy: $CFW_STAGED_IMG (the original $IMG is not written)"
txn check --phase pre-mount || exit $?
hdiutil attach -plist -nomount -imagekey diskimage-class=CRawDiskImage "$CFW_STAGED_IMG" > "$CFW_HOST_MNT/attach.log" {DISK_FD}<&-
BASEDISK=$(trap - EXIT INT TERM HUP; attached_disk) || { echo "[-] cannot identify attached disk; retaining attach.log" >&2; BASEDISK=""; exit 1; }
echo "[*] attached image: $BASEDISK"
CONT=$(diskutil info -plist "${BASEDISK}s1" | /usr/bin/plutil -extract APFSContainerReference raw -o - - 2>/dev/null || true)
SYS=$(diskutil apfs list "$CONT" 2>/dev/null | awk '/APFS Volume Disk \(Role\):/{for(i=1;i<=NF;i++) if($i ~ /^disk[0-9]+s[0-9]+$/) dev=$i} /Name:.*System \(Case-sensitive\)/{print dev; exit}')
[[ -n "$CONT" && -n "$SYS" ]] || { echo "[-] System volume not found in $CFW_STAGED_IMG" >&2; exit 1; }
echo "[*] attached: container=$CONT system=$SYS"

txn check --phase pre-install || exit $?
echo "[*] running $INSTALLER (files placed on host mounts)..."
# via env: an expansion-produced ${VAR:+NAME=val} isn't parsed as a shell assignment.
( exec {DISK_FD}<&-; cd "$VM_DIR" && env CFW_HOST_CONTAINER="$CONT" _VPHONE_PATH="$P" \
    ${SPOOF_BUILD:+SPOOF_BUILD="$SPOOF_BUILD"} \
    ${VPHONE_FRIDA:+VPHONE_FRIDA="$VPHONE_FRIDA"} \
    zsh "$SCRIPT_DIR/$INSTALLER" . )

if ! cleanup; then
  CLEANUP_DONE=1
  CLEANUP_FAILED=1
  echo "[-] CFW cleanup failed; snapshot not changed and nothing published. $IMG was not written; the staged copy may hold partial installation changes." >&2
  echo "[-] Inspect retained mounts and attach.log, unmount normally, then remove the retained staging directory and rerun the same CFW variant." >&2
  exit 1
fi
CLEANUP_DONE=1

echo "[*] flipping boot snapshot offline on the staged copy (com.apple.os.update -> live volume)..."
"$PY" "$PROJ/tools/apfs_snap_rename.py" "$CFW_STAGED_IMG"

echo "[*] publishing the staged copy as $IMG (exchange rename)..."
txn publish || exit $?
TXN_STATE=published
trap - EXIT INT TERM HUP
if ! txn finish --exit-code 0 >/dev/null; then
  echo "[!] the installed disk is published, but its transaction record or the previous-disk check did not complete; inspect $CFW_DISK_WORK and $VM_DIR/.cfw-history" >&2
fi
exec {DISK_FD}<&-

# Drop the extracted CFW input dirs (source .tar.zst re-extracts). VPHONE_KEEP_ARTIFACTS opts out.
if [[ -z "${VPHONE_KEEP_ARTIFACTS:-}" ]]; then
  rm -rf "${VM_DIR:?}/cfw_input" "${VM_DIR:?}/cfw_jb_input"
fi

# The whole install ran as root (owners-honored mounts / chown / cp). Hand the
# host-side artifacts it created (vm/.vphoned.signed, vm/.cfw_temp, extracted
# cfw_input/cfw_jb_input, the vphoned build) back to the invoking user, so the
# subsequent user-run steps (make boot / setup_machine first boot, which rewrite
# vm/.vphoned.signed) don't hit "Permission denied".
# The install is complete and the snapshot flipped by now; a mount that
# appeared beneath the VM directory meanwhile (not from this invocation, whose
# mounts were released by cleanup) only downgrades the ownership step to a
# warning. Never fail a finished install here, and never chown across it.
# Only the owner changes; no mode is widened (upstream VPhoneHostFilePermissions
# chmods 0777, which this project does not adopt). As in upstream's descriptor
# walk, the walk stays on one device (-x), follows no symbolic link (find -P;
# chown -h never follows one either), changes only directories and regular
# files with a single link, and only when root or the invoker owns them. A
# hard link could name a file outside the VM directory, and an entry of a third
# account is not the invoker's to receive; both keep their owner, and a third
# account's directory is not descended into.
# restore_invoker_ownership is defined before the disk transaction starts.
if [[ -n "${SUDO_USER:-}" ]]; then
  if [[ ! "${SUDO_UID:-}" =~ '^[0-9]+$' ]]; then
    echo "[!] ownership of host-side artifacts NOT restored: SUDO_UID is missing or not numeric" >&2
  elif assert_no_vm_mounts; then
    for artifact in .vphoned.signed .cfw_temp cfw_input cfw_jb_input .cfw-history; do
      [[ ! -L "$VM_DIR/$artifact" && -e "$VM_DIR/$artifact" ]] || continue
      restore_invoker_ownership "$VM_DIR/$artifact"
    done
    [[ -e "$PROJ/scripts/vphoned/vphoned" ]] && chown "$SUDO_USER" "$PROJ/scripts/vphoned/vphoned" 2>/dev/null || true
    echo "[*] restored ownership of host-side artifacts to $SUDO_USER (hard-linked files and other accounts' entries left as found)"
  else
    echo "[!] ownership of host-side artifacts NOT restored (mount beneath VM directory); unmount it, then: chown -Rx $SUDO_USER $VM_DIR/{.vphoned.signed,.cfw_temp,cfw_input,cfw_jb_input,.cfw-history}" >&2
  fi
fi

echo "[+] host-mode CFW install complete. Boot with: make boot"

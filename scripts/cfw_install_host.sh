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
#        cfw_install_host.sh --update-environment vm_dir
# Runs as root (mount_apfs/chown/cp to owners-honored mounts); re-execs under
# sudo automatically (honors SUDO_ASKPASS for non-interactive use). Artifacts it
# creates go back to VPHONE_INVOKER_UID[:VPHONE_INVOKER_GID] (set by vphone-cli)
# or SUDO_UID[:SUDO_GID]; see the invoker block below.
#
# --update-environment (T16) uses the same transaction for a stopped-VM guest
# environment replacement: scripts/cfw_env_update.py re-checks the staged copy,
# refuses anything other than offline_update, and replaces only libraries that
# already exist and differ from the candidates in VPHONE_GUEST_COMPONENTS
# (default .build/guest-components-v2/stage). No variant installer, patch or
# snapshot flip runs, and the recorded variant is not touched.
set -euo pipefail
SCRIPT_DIR="${0:a:h}"
PROJ="${SCRIPT_DIR:h}"

VARIANT=exp
MODE=install
VM_DIR="$PROJ/vm"
while (( $# )); do
  case "$1" in
    --variant) VARIANT="$2"; shift 2 ;;
    --update-environment) MODE=environment; shift ;;
    -*) echo "[-] unknown option: $1" >&2; exit 1 ;;
    *)         VM_DIR="$1";  shift ;;
  esac
done

if [[ "$MODE" == environment ]]; then
  INSTALLER=""
  MODE_ARGS=(--update-environment)
else
  case "$VARIANT" in
    regular) INSTALLER=cfw_install.sh ;;
    dev)     INSTALLER=cfw_install_dev.sh ;;
    jb)      INSTALLER=cfw_install_jb.sh ;;
    exp)     INSTALLER=cfw_install_exp.sh ;;
    *) echo "[-] unknown variant: $VARIANT (regular|dev|jb|exp)" >&2; exit 1 ;;
  esac
  MODE_ARGS=(--variant "$VARIANT")
fi

# Re-exec as root; owners-honored mounts + chown/cp require it.
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo ${SUDO_ASKPASS:+-A} -E /bin/zsh "$0" "${MODE_ARGS[@]}" "$VM_DIR"
fi
unset SUDO_ASKPASS   # already root: host_hdiutil/pre-step use plain sudo/hdiutil

VM_DIR="$(cd "$VM_DIR" && pwd -P)"
IMG="$VM_DIR/Disk.img"
[[ -f "$IMG" && ! -L "$IMG" ]] || { echo "[-] no Disk.img (regular file) at $IMG" >&2; exit 1; }

# The account the root-created artifacts are returned to. vphone-cli passes
# VPHONE_INVOKER_UID/GID on both of its elevation paths: the sudo re-exec
# (sudo -E keeps them) and --root-popup, whose `do shell script ... with
# administrator privileges` shell has no SUDO_* variables. A direct sudo run
# (make cfw_install) falls back to sudo's SUDO_UID/SUDO_GID. The value is
# never derived from the bundle; it is only compared with the owner of the
# bundle directory. A malformed value is refused before anything changes; a
# root invoker, an unknown invoker or one that does not own the bundle leaves
# every owner unchanged, with a warning.
INVOKER_SOURCE="" INVOKER_UID="" INVOKER_GID="" INVOKER_GID_SOURCE=""
if [[ -n "${VPHONE_INVOKER_UID:-}" ]]; then
  INVOKER_SOURCE=VPHONE_INVOKER_UID INVOKER_UID="$VPHONE_INVOKER_UID"
  INVOKER_GID_SOURCE=VPHONE_INVOKER_GID INVOKER_GID="${VPHONE_INVOKER_GID:-}"
elif [[ -n "${SUDO_UID:-}" ]]; then
  INVOKER_SOURCE=SUDO_UID INVOKER_UID="$SUDO_UID"
  INVOKER_GID_SOURCE=SUDO_GID INVOKER_GID="${SUDO_GID:-}"
fi
DECIMAL_ID='^(0|[1-9][0-9]{0,9})$'
if [[ -n "$INVOKER_SOURCE" && ! "$INVOKER_UID" =~ $DECIMAL_ID ]]; then
  echo "[-] $INVOKER_SOURCE is not a decimal uid ('$INVOKER_UID'); refusing before any change" >&2
  exit 2
fi
if [[ -n "$INVOKER_GID" && ! "$INVOKER_GID" =~ $DECIMAL_ID ]]; then
  echo "[-] $INVOKER_GID_SOURCE is not a decimal gid ('$INVOKER_GID'); refusing before any change" >&2
  exit 2
fi
INVOKER_OWNER="" HANDBACK_SKIP=""
if [[ -z "$INVOKER_SOURCE" ]]; then
  HANDBACK_SKIP="invoker uid unknown (neither VPHONE_INVOKER_UID nor SUDO_UID is set)"
elif (( INVOKER_UID == 0 )); then
  HANDBACK_SKIP="the invoker is root"
elif [[ "$(/usr/bin/stat -f %u "$VM_DIR")" != "$INVOKER_UID" ]]; then
  HANDBACK_SKIP="$INVOKER_SOURCE=$INVOKER_UID does not own $VM_DIR (owner uid $(/usr/bin/stat -f %u "$VM_DIR"))"
else
  INVOKER_OWNER="$INVOKER_UID${INVOKER_GID:+:$INVOKER_GID}"
fi

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
  exec "$PY" "$SCRIPT_DIR/vm_lock.py" "$VM_DIR" cfw -- /bin/zsh "$0" "${MODE_ARGS[@]}" "$VM_DIR"
fi
GUEST_COMPONENTS="${VPHONE_GUEST_COMPONENTS:-$PROJ/.build/guest-components-v2/stage}"

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
# above hand_back_artifacts.
restore_invoker_ownership() {
  local target="$1"
  find -x "$target" \( -type d ! -user 0 ! -user "$INVOKER_UID" -prune \) -o \
    \( \( -type d -o \( -type f -links 1 \) \) \( -user 0 -o -user "$INVOKER_UID" \) \
       -exec chown -h "$INVOKER_OWNER" {} + \)
}

# The whole install runs as root (owners-honored mounts / chown / cp). Hand the
# host-side artifacts it created (vm/.vphoned.signed, vm/.cfw_temp, extracted
# cfw_input/cfw_jb_input, the .cfw-history transaction records, the vphoned
# build) back to the invoking user on success, failure and interruption, so the
# user can read and delete them (vm delete) and later user-run steps that
# rewrite vm/.vphoned.signed don't hit "Permission denied".
# A mount beneath the VM directory (a retained mount of a failed cleanup, or one
# that appeared meanwhile) only downgrades this step to a warning; never chown
# across it, and never fail the install here.
# Only the owner changes; no mode is widened (upstream VPhoneHostFilePermissions
# chmods 0777, which this project does not adopt): a transaction record
# directory stays 0700, which its new owner can read and remove. As in
# upstream's descriptor walk, the walk stays on one device (-x), follows no
# symbolic link (find -P; chown -h never follows one either), changes only
# directories and regular files with a single link, and only when root or the
# invoker owns them. A hard link could name a file outside the VM directory,
# and an entry of a third account is not the invoker's to receive; both keep
# their owner, and a third account's directory is not descended into.
hand_back_artifacts() {
  local artifact failed=0
  if [[ -z "$INVOKER_OWNER" ]]; then
    echo "[!] ownership of host-side artifacts NOT restored: $HANDBACK_SKIP" >&2
    return 0
  fi
  if ! assert_no_vm_mounts; then
    echo "[!] ownership of host-side artifacts NOT restored (mount beneath VM directory); unmount it, then: chown -Rx $INVOKER_OWNER $VM_DIR/{.vphoned.signed,.cfw_temp,cfw_input,cfw_jb_input,.cfw-history}" >&2
    return 0
  fi
  for artifact in .vphoned.signed .cfw_temp cfw_input cfw_jb_input .cfw-history; do
    [[ ! -L "$VM_DIR/$artifact" && -e "$VM_DIR/$artifact" ]] || continue
    restore_invoker_ownership "$VM_DIR/$artifact" || failed=1
  done
  if [[ -f "$PROJ/scripts/vphoned/vphoned" && ! -L "$PROJ/scripts/vphoned/vphoned" ]]; then
    restore_invoker_ownership "$PROJ/scripts/vphoned/vphoned" 2>/dev/null || true
  fi
  if (( failed )); then
    echo "[!] ownership of some host-side artifacts NOT restored to uid $INVOKER_UID; inspect $VM_DIR" >&2
  else
    echo "[*] restored ownership of host-side artifacts to uid $INVOKER_UID (hard-linked files and other accounts' entries left as found)"
  fi
  return 0
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
  local code="$1" retain="$2"
  [[ "$TXN_STATE" != published && -d "$CFW_DISK_WORK" ]] || return 0
  txn finish --exit-code "$code" ${retain:+--retain-staged} >/dev/null || return 1
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
  hand_back_artifacts || true
  exit "$original"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ "$MODE" == environment ]]; then
  echo "[*] host-mode guest environment update: vm=$VM_DIR candidates=$GUEST_COMPONENTS mounts=$CFW_HOST_MNT staging=$CFW_DISK_WORK"
else
  echo "[*] host-mode CFW install: variant=$VARIANT vm=$VM_DIR mounts=$CFW_HOST_MNT staging=$CFW_DISK_WORK"
fi
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
ENV_REPORT="$CFW_DISK_WORK/environment-update.json"
if [[ "$MODE" == environment ]]; then
  echo "[*] checking and replacing guest environment libraries on the staged copy..."
  # Refuses (exit 3) unless the staged system volume is offline_update; the
  # report is archived with the transaction record in .cfw-history/<id>/.
  ( exec {DISK_FD}<&-; "$PY" "$SCRIPT_DIR/cfw_env_update.py" apply --device "/dev/$SYS" \
      --mount "$CFW_HOST_MNT/mnt1" --components "$GUEST_COMPONENTS" --report "$ENV_REPORT" "$VM_DIR" ) || exit $?
else
  echo "[*] running $INSTALLER (files placed on host mounts)..."
  # via env: an expansion-produced ${VAR:+NAME=val} isn't parsed as a shell assignment.
  ( exec {DISK_FD}<&-; cd "$VM_DIR" && env CFW_HOST_CONTAINER="$CONT" _VPHONE_PATH="$P" \
      ${SPOOF_BUILD:+SPOOF_BUILD="$SPOOF_BUILD"} \
      ${VPHONE_FRIDA:+VPHONE_FRIDA="$VPHONE_FRIDA"} \
      zsh "$SCRIPT_DIR/$INSTALLER" . )
fi

if ! cleanup; then
  CLEANUP_DONE=1
  CLEANUP_FAILED=1
  echo "[-] CFW cleanup failed; snapshot not changed and nothing published. $IMG was not written; the staged copy may hold partial installation changes." >&2
  echo "[-] Inspect retained mounts and attach.log, unmount normally, then remove the retained staging directory and rerun the same CFW variant." >&2
  exit 1
fi
CLEANUP_DONE=1

# The snapshot was flipped by the full install an environment update requires.
if [[ "$MODE" != environment ]]; then
  echo "[*] flipping boot snapshot offline on the staged copy (com.apple.os.update -> live volume)..."
  "$PY" "$PROJ/tools/apfs_snap_rename.py" "$CFW_STAGED_IMG"
fi

echo "[*] publishing the staged copy as $IMG (exchange rename)..."
txn publish || exit $?
TXN_STATE=published
trap - EXIT INT TERM HUP
IDENTITY_STATUS=0
if [[ "$MODE" == environment ]]; then
  # Configuration, device identity and variant records are not written by
  # this run; compare them with the digests taken before replacement.
  "$PY" "$SCRIPT_DIR/cfw_env_update.py" identity --compare "$ENV_REPORT" "$VM_DIR" || IDENTITY_STATUS=$?
fi
if ! txn finish --exit-code 0 >/dev/null; then
  echo "[!] the installed disk is published, but its transaction record or the previous-disk check did not complete; inspect $CFW_DISK_WORK and $VM_DIR/.cfw-history" >&2
fi
exec {DISK_FD}<&-

# Drop the extracted CFW input dirs (source .tar.zst re-extracts). VPHONE_KEEP_ARTIFACTS opts out.
if [[ "$MODE" != environment && -z "${VPHONE_KEEP_ARTIFACTS:-}" ]]; then
  rm -rf "${VM_DIR:?}/cfw_input" "${VM_DIR:?}/cfw_jb_input"
fi

# The install is complete and the snapshot flipped by now. The failure and
# interruption paths hand back the same artifacts from the finish trap.
hand_back_artifacts || true

if [[ "$MODE" == environment ]]; then
  echo "[+] guest environment update published; the report is in $VM_DIR/.cfw-history (environment-update.json). No process was restarted."
  if (( IDENTITY_STATUS != 0 )); then
    echo "[-] identity comparison failed (status $IDENTITY_STATUS); inspect the report before starting the VM" >&2
    exit "$IDENTITY_STATUS"
  fi
else
  echo "[+] host-mode CFW install complete. Boot with: make boot"
fi

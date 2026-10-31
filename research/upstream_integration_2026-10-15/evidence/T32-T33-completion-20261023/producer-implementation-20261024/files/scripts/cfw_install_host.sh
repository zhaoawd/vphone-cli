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
#        cfw_install_host.sh --check-environment --report /abs/new-file vm_dir
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
#
# --check-environment (T16 follow-up) runs only the read-only eligibility check
# as root and writes its JSON result to --report; see the block after PY below.
set -euo pipefail
SCRIPT_DIR="${0:a:h}"
PROJ="${SCRIPT_DIR:h}"

VARIANT="${VPHONE_CFW_VARIANT:-}"
MODE=install
GUEST_ENVIRONMENT=classic
GUEST_ENVIRONMENT_GIVEN=0
WORK_PARENT=""
REPORT=""
UNDO_GENERATION=""
UNDO_DECLARATIONS=()
REINSTALL_CRYPTEX=0
VM_DIR="$PROJ/vm"
while (( $# )); do
  case "$1" in
    --variant) VARIANT="$2"; shift 2 ;;
    --work-parent)
      (( $# >= 2 )) || { echo "[-] --work-parent needs an absolute directory" >&2; exit 1; }
      WORK_PARENT="$2"; [[ "$WORK_PARENT" == /* ]] || { echo "[-] --work-parent must be absolute" >&2; exit 1; }; shift 2 ;;
    --reinstall-cryptex) REINSTALL_CRYPTEX=1; shift ;;
    --guest-environment)
      (( $# >= 2 )) || { echo "[-] --guest-environment needs classic|v2" >&2; exit 1; }
      GUEST_ENVIRONMENT="$2"; GUEST_ENVIRONMENT_GIVEN=1; shift 2 ;;
    --install-environment) echo "[-] standalone environment migration is not enabled yet" >&2; exit 1 ;;
    --undo-declaration)
      (( $# >= 2 )) || { echo "[-] --undo-declaration needs an ID" >&2; exit 1; }
      [[ "$MODE" == install || "$MODE" == undo ]] || { echo "[-] Undo cannot be combined with environment modes" >&2; exit 1; }
      MODE=undo; UNDO_DECLARATIONS+=("$2"); shift 2 ;;
    --generation)
      (( $# >= 2 )) || { echo "[-] --generation needs a digest" >&2; exit 1; }
      UNDO_GENERATION="$2"; shift 2 ;;
    --update-environment|--check-environment)
      [[ "$MODE" == install ]] || { echo "[-] --update-environment and --check-environment are exclusive" >&2; exit 1; }
      [[ "$1" == --update-environment ]] && MODE=environment || MODE=check
      shift ;;
    --report) (( $# >= 2 )) || { echo "[-] --report needs a file path" >&2; exit 1; }; REPORT="$2"; shift 2 ;;
    -*) echo "[-] unknown option: $1" >&2; exit 1 ;;
    *)         VM_DIR="$1";  shift ;;
  esac
done

case "$GUEST_ENVIRONMENT" in
  classic|v2) ;;
  *) echo "[-] unknown guest environment: $GUEST_ENVIRONMENT (classic|v2)" >&2; exit 1 ;;
esac
if (( GUEST_ENVIRONMENT_GIVEN )) && [[ "$MODE" != install ]]; then
  echo "[-] --guest-environment is only valid for CFW installation" >&2; exit 1
fi
if (( REINSTALL_CRYPTEX )) && [[ "$MODE" != install || "$VARIANT" != regular || "$GUEST_ENVIRONMENT" != classic ]]; then
  echo "[-] --reinstall-cryptex requires regular/classic CFW installation" >&2; exit 1
fi
# B1 profile contract: initial v2 rollout supports regular only.
if [[ "$GUEST_ENVIRONMENT" == v2 && "$VARIANT" != regular ]]; then
  echo "[-] guest environment v2 supports only variant regular" >&2; exit 1
fi

if [[ "$MODE" == undo ]]; then
  [[ -n "$UNDO_GENERATION" ]] || { echo "[-] Undo requires --generation" >&2; exit 1; }
  INSTALLER=""
  MODE_ARGS=(--variant "$VARIANT" --generation "$UNDO_GENERATION")
  for declaration in "${UNDO_DECLARATIONS[@]}"; do MODE_ARGS+=(--undo-declaration "$declaration"); done
elif [[ -n "$UNDO_GENERATION" ]]; then
  echo "[-] --generation requires --undo-declaration" >&2; exit 1
elif [[ "$MODE" == check ]]; then
  [[ "$REPORT" == /* ]] || { echo "[-] --check-environment requires --report with an absolute file path" >&2; exit 1; }
  INSTALLER=""
  MODE_ARGS=(--check-environment --report "$REPORT")
elif [[ -n "$REPORT" ]]; then
  echo "[-] --report is only valid with --check-environment" >&2; exit 1
elif [[ "$MODE" == environment ]]; then
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
  [[ "$GUEST_ENVIRONMENT" == classic ]] || MODE_ARGS+=(--guest-environment "$GUEST_ENVIRONMENT")
  (( ! REINSTALL_CRYPTEX )) || MODE_ARGS+=(--reinstall-cryptex)
fi

[[ -z "$WORK_PARENT" ]] || MODE_ARGS+=(--work-parent "$WORK_PARENT")

# The canonical restore-info writer uses this literal JSON field. Refuse a
# classic reinstall before elevation or disk tools can remove the API entry.
V2_RECORD_PATTERN='"guest_environment"[[:space:]]*:[[:space:]]*"v2"'
if [[ "$MODE" == install && "$GUEST_ENVIRONMENT" == classic && -f "$VM_DIR/restore-info.json" ]] \
    && [[ "$(<"$VM_DIR/restore-info.json")" =~ $V2_RECORD_PATTERN ]]; then
  echo "[-] this VM records v2; reinstall with --guest-environment v2" >&2; exit 1
fi

# A direct script invocation cannot invent defaults or bypass Swift validation.
if [[ "$MODE" != check ]]; then
  [[ -n "$VARIANT" && "$VARIANT" == "${VPHONE_CFW_VARIANT:-}" ]] || { echo "[-] variant differs from bound frozen plan" >&2; exit 1; }
  "${VPHONE_PYTHON:-$PROJ/.venv/bin/python3}" "$SCRIPT_DIR/patchers/plan_gate.py" entry "${0:t}" || exit $?
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
# Python imports must not create root-owned files in the app or source resources.
export PYTHONDONTWRITEBYTECODE=1

# --check-environment: the read-only eligibility check, run as root because a
# normal user may not mount a VM's System volume (real host, 2026-10-01). It
# takes no lock record, creates nothing in the VM directory and changes no
# owner there: cfw_env_update.py check-vm holds the directory flock, attaches
# Disk.img read-only, mounts read-only beneath the system temporary directory,
# unmounts and detaches, and writes its result to REPORT, a new file in the
# caller's private directory, owned by the invoker. The invoker comes from the
# same variables as above; the owner of the report directory, not of the
# bundle, must match it (checked by check-vm before the disk is touched).
if [[ "$MODE" == check ]]; then
  OWNER_ARGS=()
  if [[ -n "$INVOKER_SOURCE" ]] && (( INVOKER_UID != 0 )); then
    OWNER_ARGS=(--owner "$INVOKER_UID${INVOKER_GID:+:$INVOKER_GID}")
  fi
  echo "[*] read-only guest environment check as uid ${EUID:-$(id -u)}: vm=$VM_DIR report=$REPORT" >&2
  # No root-owned __pycache__ beside the scripts.
  export PYTHONDONTWRITEBYTECODE=1
  exec "$PY" "$SCRIPT_DIR/cfw_env_update.py" check-vm \
    --components "${VPHONE_GUEST_COMPONENTS:-$PROJ/.build/guest-components-v2/stage}" \
    --report "$REPORT" "${OWNER_ARGS[@]}" "$VM_DIR"
fi

# Acquire after sudo, which may close inherited descriptors. The re-executed
# operation tree must prove possession of the directory descriptor.
if ! "$PY" "$SCRIPT_DIR/vm_lock.py" --check-inherited "$VM_DIR"; then
  [[ -z "${VPHONE_CFW_LOCK_REEXEC:-}" ]] || { echo "[-] inherited CFW lock validation failed" >&2; exit 1; }
  export VPHONE_CFW_LOCK_REEXEC=1
  exec "$PY" "$SCRIPT_DIR/vm_lock.py" "$VM_DIR" cfw -- /bin/zsh "$0" "${MODE_ARGS[@]}" "$VM_DIR"
fi
"$PY" "$SCRIPT_DIR/patchers/plan_gate.py" entry "${0:t}" || exit $?
GUEST_COMPONENTS="${VPHONE_GUEST_COMPONENTS:-$PROJ/.build/guest-components-v2/stage}"
API_DAEMON="${VPHONE_API_DAEMON:-$PROJ/.build/daemon-api-v2/candidate-v2}"

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
    \( \( -type d -o \( -type f -links 1 ! -name guest-origin-attestation.json \) \) \( -user 0 -o -user "$INVOKER_UID" \) \
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
  local artifacts=(.vphoned.signed .cfw_temp cfw_input cfw_jb_input .cfw-history)
  [[ "$MODE" != undo ]] || artifacts=(.cfw-history "${CFW_DISK_WORK:t}")
  for artifact in "${artifacts[@]}"; do
    [[ -n "$artifact" ]] || continue
    [[ ! -L "$VM_DIR/$artifact" && -e "$VM_DIR/$artifact" ]] || continue
    restore_invoker_ownership "$VM_DIR/$artifact" || failed=1
  done
  if [[ "$MODE" != undo && -f "$PROJ/scripts/vphoned/vphoned" && ! -L "$PROJ/scripts/vphoned/vphoned" ]]; then
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
CFW_DISK_WORK=""
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

# Disk staging stays inside the VM for same-volume atomic publication.
# An explicit scratch parent changes only the private mount workspace.
make_mount_directory() {
  if [[ -z "$WORK_PARENT" ]]; then
    mktemp -d "$VM_DIR/.cfw_mount.XXXXXXXX"
  else
    "$PY" -c 'import sys; sys.path.insert(0,sys.argv[1]); from cfw_disk_txn import make_mount_directory; print(make_mount_directory(sys.argv[2]))' "$SCRIPT_DIR" "$WORK_PARENT"
  fi
}
# Check both volumes before creating any disk copy. statvfs is also available
# on external volumes that have no Foundation important-usage capacity value.
"$PY" -c 'import sys; sys.path.insert(0,sys.argv[1]); from cfw_disk_txn import require_free_space; require_free_space(sys.argv[2:])' "$SCRIPT_DIR" "$VM_DIR" "${WORK_PARENT:-$VM_DIR}"
CFW_HOST_MNT=$(make_mount_directory)
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

# Preflight workspace failures must not leave an empty pending transaction.
# The cleanup trap already owns the mount root before disk staging starts.
exec {DISK_FD}<"$IMG"
CFW_DISK_WORK=$(mktemp -d "$VM_DIR/.cfw_disk.XXXXXXXX")
export VPHONE_GUEST_EVIDENCE="$CFW_DISK_WORK/guest-changes.jsonl"

if [[ "$MODE" == environment ]]; then
  echo "[*] host-mode guest environment update: vm=$VM_DIR candidates=$GUEST_COMPONENTS mounts=$CFW_HOST_MNT staging=$CFW_DISK_WORK"
else
  echo "[*] host-mode CFW install: variant=$VARIANT vm=$VM_DIR mounts=$CFW_HOST_MNT staging=$CFW_DISK_WORK"
fi
# zsh does not run the EXIT trap when ERR_EXIT fires inside a function, so
# every failing txn call exits explicitly at top level.
if [[ "$MODE" == environment ]]; then
  CFW_STAGED_IMG=$(txn stage) || exit $?
elif [[ "$MODE" == install ]]; then
  CFW_STAGED_IMG=$(txn stage --guest-evidence --invalidate-guest-origin) || exit $?
else
  CFW_STAGED_IMG=$(txn stage --guest-evidence) || exit $?
fi
TXN_STATE=staged
echo "[*] staged copy: $CFW_STAGED_IMG (the original $IMG is not written)"
if [[ "$MODE" == undo ]]; then
  UNDO_ARGS=(--generation "$UNDO_GENERATION")
  for declaration in "${UNDO_DECLARATIONS[@]}"; do UNDO_ARGS+=(--declaration "$declaration"); done
  txn prepare-undo "${UNDO_ARGS[@]}" || exit $?
fi
if [[ "$MODE" == install ]]; then
  echo "[*] capturing generation-backed file originals from readonly source images..."
  ( exec {DISK_FD}<&-; "$PY" "$SCRIPT_DIR/patchers/file_originals.py" prepare "$CFW_DISK_WORK" ) || exit $?
fi
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
elif [[ "$MODE" == undo ]]; then
  echo "[*] restoring qualified component originals on the staged volumes..."
  txn apply-undo || exit $?
else
  echo "[*] running $INSTALLER (files placed on host mounts)..."
  # via env: an expansion-produced ${VAR:+NAME=val} isn't parsed as a shell assignment.
  ( exec {DISK_FD}<&-; cd "$VM_DIR" && env CFW_HOST_CONTAINER="$CONT" _VPHONE_PATH="$P" VPHONE_REINSTALL_CRYPTEX="$REINSTALL_CRYPTEX" \
      ${SPOOF_BUILD:+SPOOF_BUILD="$SPOOF_BUILD"} \
      ${VPHONE_FRIDA:+VPHONE_FRIDA="$VPHONE_FRIDA"} \
      zsh "$SCRIPT_DIR/$INSTALLER" . )
  if [[ "$GUEST_ENVIRONMENT" == v2 ]]; then
    TRANSACTION_ID=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$CFW_DISK_WORK/transaction.json")
    echo "[*] installing v2 guest environment on the staged System volume..."
    ( exec {DISK_FD}<&-; "$PY" "$SCRIPT_DIR/cfw_env_install.py" install --device "/dev/$SYS" \
        --mount "$CFW_HOST_MNT/mnt1" --components "$GUEST_COMPONENTS" --daemon "$API_DAEMON" \
        --variant "$VARIANT" --transaction-id "$TRANSACTION_ID" \
        --report "$CFW_DISK_WORK/guest-environment-install.json" "$VM_DIR" ) || exit $?
  fi
fi

echo "[*] verifying final guest effects on the staged image..."
"$PY" "$SCRIPT_DIR/patchers/plan_gate.py" verify-final || exit $?

if ! cleanup; then
  CLEANUP_DONE=1
  CLEANUP_FAILED=1
  echo "[-] CFW cleanup failed; snapshot not changed and nothing published. $IMG was not written; the staged copy may hold partial installation changes." >&2
  echo "[-] Inspect retained mounts and attach.log, unmount normally, then remove the retained staging directory and rerun the same CFW variant." >&2
  exit 1
fi
CLEANUP_DONE=1

# The snapshot was flipped by the full install an environment update requires.
if [[ "$MODE" == install ]]; then
  echo "[*] flipping boot snapshot offline on the staged copy (com.apple.os.update -> live volume)..."
  "$PY" "$PROJ/tools/apfs_snap_rename.py" "$CFW_STAGED_IMG"
fi

if [[ "$MODE" != environment ]]; then
  # Verify the actual post-snapshot image. Its final attachment and all volume
  # mounts are read-only; no writer runs after this boundary.
  CFW_HOST_MNT=$(make_mount_directory)
  export CFW_HOST_MNT
  CLEANUP_DONE=0
  txn bind-mount || exit $?
  hdiutil attach -plist -nomount -readonly -imagekey diskimage-class=CRawDiskImage "$CFW_STAGED_IMG" > "$CFW_HOST_MNT/attach.log" {DISK_FD}<&-
  BASEDISK=$(trap - EXIT INT TERM HUP; attached_disk) || { echo "[-] cannot identify final read-only attachment" >&2; BASEDISK=""; exit 1; }
  echo "[*] verifying final guest effects after snapshot modification..."
  "$PY" "$SCRIPT_DIR/patchers/plan_gate.py" verify-final || exit $?
  if ! cleanup; then
    CLEANUP_DONE=1
    CLEANUP_FAILED=1
    echo "[-] final read-only attachment cleanup failed; nothing published" >&2
    exit 1
  fi
  CLEANUP_DONE=1
  txn seal || exit $?
fi

echo "[*] publishing the staged copy as $IMG (exchange rename)..."
"$PY" "$SCRIPT_DIR/patchers/plan_gate.py" entry "${0:t}" || exit $?
txn publish || exit $?
TXN_STATE=published
trap - EXIT INT TERM HUP
IDENTITY_STATUS=0
FINALIZE_STATUS=0
if [[ "$MODE" == environment ]]; then
  # Configuration, device identity and variant records are not written by
  # this run; compare them with the digests taken before replacement.
  "$PY" "$SCRIPT_DIR/cfw_env_update.py" identity --compare "$ENV_REPORT" "$VM_DIR" || IDENTITY_STATUS=$?
fi
if ! txn finish --exit-code 0 >/dev/null; then
  FINALIZE_STATUS=1
  echo "[!] the installed disk is published, but its transaction record or the previous-disk check did not complete; inspect $CFW_DISK_WORK and $VM_DIR/.cfw-history" >&2
fi
exec {DISK_FD}<&-
if (( FINALIZE_STATUS != 0 )); then
  hand_back_artifacts || true
  echo "[-] publication finalization is incomplete; inspect retained evidence before starting the VM" >&2
  exit "$FINALIZE_STATUS"
fi

# Drop the extracted CFW input dirs (source .tar.zst re-extracts). VPHONE_KEEP_ARTIFACTS opts out.
if [[ "$MODE" == install && -z "${VPHONE_KEEP_ARTIFACTS:-}" ]]; then
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
elif [[ "$MODE" == undo ]]; then
  echo "[+] guest component Undo published with component receipts; guest origin is unknown. Evidence: $VM_DIR/.cfw-history"
else
  echo "[+] host-mode CFW install complete. Boot with: make boot"
fi

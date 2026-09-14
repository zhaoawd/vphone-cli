#!/bin/zsh
# Shared CFW installation primitives. Source after defining SCRIPT_DIR and VM_DIR.
# Variant stages and signing-with-entitlements policies remain in the entrypoints.
set -euo pipefail

die() {
    echo "[-] $*" >&2
    exit 1
}

_resolve_python3() {
    if [[ -n "${VPHONE_PYTHON:-}" ]]; then
        echo "$VPHONE_PYTHON"
        return
    fi
    local venv_py="${SCRIPT_DIR:h}/.venv/bin/python3"
    if [[ -x "$venv_py" ]]; then
        echo "$venv_py"
    else
        command -v python3 || true
    fi
}

ldid_sign() {
    local file="$1" bundle_id="${2:-}"
    local args=(-S -M "-K$VM_DIR/$CFW_INPUT/signcert.p12")
    [[ -n "$bundle_id" ]] && args+=("-I$bundle_id")
    ldid "${args[@]}" "$file"
}

host_hdiutil() {
    local rc
    # SUDO_PASSWORD flow exports SUDO_ASKPASS: go straight to sudo -A so
    # hdiutil never runs unprivileged first (which triggers an auth prompt).
    [[ -n "${SUDO_ASKPASS:-}" ]] && { sudo -A hdiutil "$@"; return; }

    hdiutil "$@" && return 0
    rc=$?

    if sudo -n true 2>/dev/null; then
        sudo hdiutil "$@"
        return
    fi

    return "$rc"
}

assert_mount_under_vm() {
    local mnt="$1" label="${2:-mountpoint}"
    local abs_vm abs_mnt

    abs_vm="$(cd "$VM_DIR" && pwd -P)"
    abs_mnt="$(cd "$mnt" && pwd -P)"
    case "$abs_mnt/" in
        "$abs_vm/"*) ;;
        *) die "Unsafe ${label}: ${abs_mnt} (must be inside ${abs_vm})" ;;
    esac
}

find_restore_dir() {
    for dir in "$VM_DIR"/iPhone*_Restore; do
        [[ -f "$dir/BuildManifest.plist" ]] && echo "$dir" && return
    done
    die "No restore directory found in $VM_DIR"
}

mount_vol() {  # mount_vol <slice, e.g. s1> <mountpoint> [opts]
    local dev="/dev/${CFW_HOST_CONTAINER}$1" mnt="$2" opts="${3:-rw}"
    /bin/mkdir -p "$mnt"
    /sbin/mount | /usr/bin/grep -Fq " on $mnt " && return 0
    /sbin/mount_apfs -o "$opts" "$dev" "$mnt" 2>/dev/null || true
    /sbin/mount | /usr/bin/grep -Fq " on $mnt " || die "mount failed: $dev -> $mnt"
}

# Selection is read-only here: environment creation belongs to setup.
# Use D2's actual capability and lock probe before any installer writes.
cfw_require_runtime_and_lock() {
    PYTHON3="$(_resolve_python3)"
    [[ -x "$PYTHON3" ]] || die "python3 not found. Run: make setup_venv"
    "$PYTHON3" "$SCRIPT_DIR/check_python_runtime.py" --locked || die "Python runtime invalid. Run: make setup_venv"
    "$PYTHON3" "$SCRIPT_DIR/vm_lock.py" --check-inherited "$VM_DIR" || die "VM lock missing — run via cfw_install_host.sh"
}

check_prereqs() {
    command -v ipsw >/dev/null 2>&1 || die "'ipsw' not found. Install: brew install blacktop/tap/ipsw"
    command -v aea >/dev/null 2>&1 || die "'aea' not found (requires macOS 12+)"
    echo "[*] Python: $PYTHON3 ($("$PYTHON3" --version 2>&1))"
}

cfw_init_mounts() {
    : "${CFW_HOST_CONTAINER:?CFW_HOST_CONTAINER unset — run via cfw_install_host.sh}"
    HOST_MNT="${CFW_HOST_MNT:?CFW_HOST_MNT unset — run via cfw_install_host.sh}"
    MNT1="$HOST_MNT/mnt1"
    MNT3="$HOST_MNT/mnt3"
    MNT5="$HOST_MNT/mnt5"
    TAR="$(command -v gtar 2>/dev/null || echo /opt/homebrew/bin/gtar)"
    mkdir -p "$HOST_MNT"
}

# Keep each entrypoint's tar executable/options explicit.
cfw_extract_input() {
    local input="$1" archive_name="$2" failure="$3"
    shift 3
    [[ -d "$VM_DIR/$input" ]] && return 0
    local search_dir archive
    for search_dir in "$SCRIPT_DIR/resources" "$SCRIPT_DIR" "$VM_DIR"; do
        archive="$search_dir/$archive_name"
        if [[ -f "$archive" ]]; then
            echo "  Extracting $archive_name..."
            "$@" -xf "$archive" -C "$VM_DIR"
            return
        fi
    done
    die "$failure"
}

cfw_cache_systemos() {
    "$PYTHON3" "$SCRIPT_DIR/cache_systemos.py" "$1" "$2"
}

cfw_cache_appos() {
    if [[ ! -f "$2" ]]; then
        cp "$1" "$2"
    else
        echo "  Using cached AppOS DMG"
    fi
}

# Base uses host_hdiutil's fallback; DEV retains its explicit sudo policy.
cfw_detach_with() {
    local mnt="$1"
    shift
    if mount | grep -Fq " on $mnt "; then
        "$@" detach -force "$mnt" 2>/dev/null || true
    fi
}

cleanup_on_exit() {
    safe_detach "$CFW_HOST_MNT/mnt_sysos" 2>/dev/null || true
    safe_detach "$CFW_HOST_MNT/mnt_appos" 2>/dev/null || true
}

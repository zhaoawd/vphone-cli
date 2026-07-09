#!/bin/bash
# vphone_sshd.sh — Persistent OpenSSH bring-up for the JB variant.
#
# Deployed to /cores/ during cfw_install_jb.sh (ramdisk phase) and started by
# the com.vphone.sshd LaunchDaemon at EVERY boot (RunAtLoad + KeepAlive).
#
# Replaces the host-side ssh_bringup step: it self-heals host keys and runs
# OpenSSH sshd on port 22 in the foreground so launchd keeps it alive.
# The only remaining host-side piece is the usbmux->TCP port forward
# (2222 -> 22), which is inherently a host process (see `make ssh_forward`).
#
# Notes:
#   - OpenSSH (openssh-server) is installed by the user from Sileo after first
#     boot. Until then sshd does not exist; this script waits briefly for the
#     jailbreak environment to settle, then exits 0 cleanly. It is picked up
#     automatically on the next boot once openssh-server is present.
#   - Idempotent. Logs to /var/log/vphone_sshd.log.

set -uo pipefail

LOG="/var/log/vphone_sshd.log"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
SSHD_WAIT_SECONDS="${SSHD_WAIT_SECONDS:-90}"

exec >> "$LOG" 2>&1
log "=== vphone_sshd.sh starting ==="

# ── Discover PATH dynamically (procursus + iosbinpack64 + base) ──
P=""
for d in \
    /var/jb/usr/bin /var/jb/bin /var/jb/sbin /var/jb/usr/sbin /var/jb/usr/local/bin /var/jb/usr/local/sbin \
    /iosbinpack64/bin /iosbinpack64/usr/bin /iosbinpack64/sbin /iosbinpack64/usr/sbin \
    /usr/bin /usr/sbin /bin /sbin; do
    [ -d "$d" ] && P="$P:$d"
done
export PATH="${P#:}:$PATH"

# ── Locate sshd ─────────────────────────────────────────────────
SSHD=""
locate_sshd() {
    SSHD=""
    for cand in \
        /var/jb/usr/sbin/sshd \
        /var/jb/usr/local/sbin/sshd \
        /usr/sbin/sshd \
        "$(command -v sshd 2>/dev/null || true)"; do
        if [ -n "$cand" ] && [ -x "$cand" ]; then
            SSHD="$cand"
            return 0
        fi
    done
    return 1
}

deadline=$((SECONDS + SSHD_WAIT_SECONDS))
while ! locate_sshd; do
    if (( SECONDS >= deadline )); then
        log "sshd not found after ${SSHD_WAIT_SECONDS}s — openssh-server may not be installed yet. Exiting 0 (will retry next boot)."
        exit 0
    fi
    log "sshd not found yet — waiting for jailbreak/procursus paths to settle..."
    sleep 5
done
log "sshd: $SSHD"

# ── Derive prefix / sysconfdir from the sshd path ───────────────
# .../usr/sbin/sshd -> PREFIX=...   sysconfdir = $PREFIX/etc/ssh
PREFIX="${SSHD%/usr/sbin/sshd}"
[ "$PREFIX" = "$SSHD" ] && PREFIX="${SSHD%/usr/local/sbin/sshd}"
[ "$PREFIX" = "$SSHD" ] && PREFIX=""   # system /usr/sbin/sshd -> empty prefix (sysconfdir /etc/ssh)
SSHDIR="${PREFIX}/etc/ssh"
CONF="$SSHDIR/sshd_config"
log "prefix='$PREFIX' sshdir='$SSHDIR'"

# ── Ensure sysconfdir + privilege-separation dir exist ──────────
/bin/mkdir -p "$SSHDIR"
PRIVSEP="${PREFIX}/var/empty"
/bin/mkdir -p "$PRIVSEP"
/usr/sbin/chown 0:0 "$PRIVSEP" 2>/dev/null || true
/bin/chmod 0755 "$PRIVSEP" 2>/dev/null || true

# ── Self-heal host keys (generate any that are missing) ─────────
KEYGEN="$(command -v ssh-keygen 2>/dev/null || true)"
if [ -n "$KEYGEN" ]; then
    for t in rsa ecdsa ed25519; do
        key="$SSHDIR/ssh_host_${t}_key"
        if [ ! -f "$key" ]; then
            log "generating host key: $key"
            "$KEYGEN" -q -t "$t" -N "" -f "$key" || log "  WARN: keygen $t failed"
            /bin/chmod 0600 "$key" 2>/dev/null || true
        fi
    done
else
    log "WARN: ssh-keygen not found; relying on existing host keys"
fi

# ── Run sshd in the foreground on :22 (launchd keeps it alive) ───
ARGS=(-D -e -p 22)
[ -f "$CONF" ] && ARGS+=(-f "$CONF")
ARGS+=(-o PermitRootLogin=yes -o PasswordAuthentication=yes)
log "exec: $SSHD ${ARGS[*]}"
exec "$SSHD" "${ARGS[@]}"

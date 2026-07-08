#!/bin/zsh
# ssh_forward.sh — host-side usbmux -> TCP forward for guest SSH.
#
# Bridges localhost:<port> -> guest:22 via pymobiledevice3/usbmux. This is the
# only part of SSH bring-up that must run on the host (the guest sshd itself is
# now started in-VM by the com.vphone.sshd LaunchDaemon). Resilient: waits for
# the VM's usbmux device to appear and retries, so it can be launched before or
# during boot. Cleans up its pymobiledevice3 child on TERM/INT/EXIT.
#
# Target isolation: set SSH_FWD_SERIAL=<UDID> to pin the forward to one device
# (passed through as --serial). Without it, usbmux picks whatever device is
# visible, which is wrong when a physical device or multiple VMs are attached.
#
# Usage:  PMD3_PYTHON=/path/to/venv/python3 SSH_FWD_SERIAL=<UDID> ./ssh_forward.sh [local_port]
set -uo pipefail

PORT="${1:-2222}"
PY="${PMD3_PYTHON:-$(command -v python3 || true)}"
SERIAL="${SSH_FWD_SERIAL:-}"

child=""
cleanup() { [[ -n "$child" ]] && kill "$child" 2>/dev/null; exit 0; }
trap cleanup INT TERM EXIT

if [[ -z "$PY" ]] || ! "$PY" -c "import pymobiledevice3" >/dev/null 2>&1; then
    echo "[ssh_forward] pymobiledevice3 not available (run: make setup_venv) — skipping forward"
    exit 0
fi

fwd_args=(usbmux forward "$PORT" 22)
if [[ -n "$SERIAL" ]]; then
    fwd_args+=(--serial "$SERIAL")
    echo "[ssh_forward] localhost:${PORT} -> guest:22 (device ${SERIAL}, Ctrl-C to stop)"
else
    echo "[ssh_forward] localhost:${PORT} -> guest:22 (no device pin — set SSH_FWD_SERIAL to isolate, Ctrl-C to stop)"
fi

# Retry loop: tolerate the usbmux device not being up yet. A forward that dies
# almost immediately (< 3s) usually means the local port is already taken or no
# matching device exists — surface that instead of silently spinning forever.
fast_fails=0
while true; do
    start=$SECONDS
    "$PY" -m pymobiledevice3 "${fwd_args[@]}" &
    child=$!
    wait "$child"
    child=""
    if (( SECONDS - start < 3 )); then
        fast_fails=$(( fast_fails + 1 ))
        if (( fast_fails == 3 )); then
            echo "[ssh_forward] WARN: forward keeps exiting immediately — local port ${PORT} may be in use, or no${SERIAL:+ matching} usbmux device is present. Still retrying…" >&2
        fi
    else
        fast_fails=0
    fi
    sleep 2
done

#!/bin/zsh
set -euo pipefail
root="${0:a:h:h:h:h:h}"
source_file="${1:-${0:a:h}/three-issues-runtime.zsh}"
mkdir -p "$root/.build/runtime-cleanup-tests"
fixture=$(mktemp -d "$root/.build/runtime-cleanup-tests/run.XXXXXXXX")
out="$fixture"
library="$fixture/library"
machine=fixture
socket="$fixture/vphone.sock"
launch_pid=99999999
rpc_calls=0
open_state=1
rpc_failure=0

vphone_host_request() {
    [[ "$2" == *'"method":"system.shutdown"'* ]] || return 2
    rpc_calls=$((rpc_calls + 1))
    (( ! rpc_failure )) || return 1
    open_state=0
    print '{"ok":true,"result":{"accepted":true}}'
}
kill() { return 1; }
lsof() { (( open_state )); }
sleep() { :; }
wait() { :; }

# Import only the production cleanup function, never its boot commands.
eval "$(sed -n '/^cleanup() {/,/^}/p' "$source_file")"
active=1
if ! cleanup; then
    print -u2 'A dead launcher must still shut the guest down through its socket'
    exit 1
fi
(( rpc_calls == 1 && active == 0 && open_state == 0 )) || exit 1

active=1
open_state=1
rpc_failure=1
if cleanup; then
    print -u2 'A remaining VM state handle must prevent cleanup success'
    exit 1
fi
(( rpc_calls == 2 && open_state == 1 )) || exit 1
print 'Runtime cleanup: orphaned launcher shutdown and retained-handle refusal passed'

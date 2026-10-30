#!/bin/zsh
# Print one JSON line with a running windowed acceptance VM's window frame
# (Accessibility, screen points) and the VM view bounds from the host socket.
#   window-frame.zsh <baseline|candidate>
set -euo pipefail
source "${0:a:h}/host-request.zsh"
repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
variant="${1:?usage: window-frame.zsh <baseline|candidate>}"
[[ "$variant" == baseline || "$variant" == candidate ]] || exit 2
machine="duo-$variant-20261030"
vm_pid=$(pgrep -f "vphone-vm.*$machine" | head -1)
frame=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $vm_pid) to get {position, size} of window 1" | tr -d ' ')
view=$(vphone_host_request "$repo_root/.build/acceptance/machines/$machine/vphone.sock" '{"t":"display.geometry","screen":false}' \
    | jq -c '.result.view.view_bounds')
jq -nc --arg variant "$variant" --arg frame "$frame" --argjson view "$view" \
    '{variant:$variant, at:(now|todate), window:($frame|split(",")|map(tonumber)), view_bounds:$view}'

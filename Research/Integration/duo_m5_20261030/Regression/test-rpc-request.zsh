#!/bin/zsh
set -euo pipefail
source "${0:a:h}/rpc-request.zsh"

vphone_rpc_request device.info | jq -e '. == {t:"rpc",method:"device.info",params:{}}' >/dev/null
vphone_rpc_request input.tap '{"x":1,"y":2}' | jq -e '.params == {x:1,y:2}' >/dev/null
vphone_rpc_request 'a"b' '{"text":"line\nquote\""}' \
    | jq -e '.method == "a\"b" and .params.text == "line\nquote\""' >/dev/null
if vphone_rpc_request input.tap not-json >/dev/null 2>&1; then
    print -u2 'Invalid JSON was accepted'; exit 1
fi
if vphone_rpc_request input.tap '[]' >/dev/null 2>&1; then
    print -u2 'Non-object params were accepted'; exit 1
fi
print 'RPC request contract: 5 checks passed'

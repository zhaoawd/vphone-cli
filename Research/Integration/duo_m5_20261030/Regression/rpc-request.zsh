# Pure request encoder, sourced by the acceptance harness and its contract test.
vphone_rpc_request() {
    local method="${1:?RPC method required}" params='{}'
    if (( $# >= 2 )); then params="$2"; fi
    jq -cen --arg method "$method" --argjson params "$params" '
        if ($params | type) == "object" then
            {t:"rpc",method:$method,params:$params}
        else error("RPC params must be an object") end'
}

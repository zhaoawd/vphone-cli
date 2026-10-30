# One host-control request and exactly one successful JSON reply.
vphone_host_request() {
    local socket_path="$1" payload="$2" response
    # The server already supports deep machine directories. nc needs the
    # basename from inside that directory to stay within sun_path's limit.
    response=$(cd "${socket_path:h}" && print -r -- "$payload" | nc -U -w 40 "./${socket_path:t}") || return 1
    print -r -- "$response" | jq -se 'length == 1 and (.[0] | type) == "object" and .[0].ok == true' >/dev/null || {
        print -u2 -- "$response"
        return 1
    }
    print -r -- "$response"
}

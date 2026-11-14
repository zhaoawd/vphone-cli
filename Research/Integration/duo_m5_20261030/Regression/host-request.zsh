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

# Resolve the historical target names or an explicit socket on a disposable VM.
vphone_acceptance_socket() {
    local repo_root="$1" target="$2" socket_path
    case "$target" in
        baseline|candidate) socket_path="$repo_root/.build/acceptance/machines/duo-$target-20261030/vphone.sock" ;;
        /*/vphone.sock) socket_path="$target" ;;
        *) print -u2 'Expected baseline, candidate or an absolute vphone.sock path'; return 2 ;;
    esac
    socket_path="${socket_path:A}"
    [[ "$socket_path" == "$repo_root/.build/"*/vphone.sock && -S "$socket_path" ]] || {
        print -u2 "Expected a running acceptance VM socket below $repo_root/.build"
        return 2
    }
    print -r -- "$socket_path"
}

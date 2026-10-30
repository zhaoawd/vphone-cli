#!/bin/zsh
set -euo pipefail
test_root="${0:a:h}"
repo_root="$(cd "$test_root/../../../.." && pwd)"
source "$test_root/host-request.zsh"
work="$repo_root/.build/validation/host-request-$(uuidgen)"
directory="$work/a-directory-that-forces-the-absolute-unix-socket-path-beyond-sun-path"
mkdir -p "$directory"
/usr/bin/clang -Wall -Wextra -Werror "$test_root/socket-fixture.c" -o "$work/socket-fixture"
failures=0

run_case() {
    local tag="$1" reply="$2" path_kind="$3" expected="$4" result server_pid
    (cd "$directory" && "$work/socket-fixture" vphone.sock "$reply") &
    server_pid=$!
    for attempt in {1..100}; do
        [[ ! -S "$directory/vphone.sock" ]] || break
        sleep 0.02
    done
    if [[ "$path_kind" == relative ]]; then
        if (cd "$directory" && vphone_host_request vphone.sock '{"t":"fixture"}') > "$work/$tag.json" 2> "$work/$tag.err"; then result=0; else result=1; fi
    else
        if vphone_host_request "$directory/vphone.sock" '{"t":"fixture"}' > "$work/$tag.json" 2> "$work/$tag.err"; then result=0; else result=1; fi
    fi
    if ! wait "$server_pid"; then
        print -u2 "Fixture did not complete: $tag"
        failures=$((failures + 1))
    fi
    if [[ "$expected" == success ]]; then
        if (( result != 0 )) || ! jq -se 'length == 1 and .[0].ok == true and .[0].result.fixture == true' "$work/$tag.json" >/dev/null; then
            print -u2 "Expected one successful reply: $tag"
            failures=$((failures + 1))
        fi
    elif (( result == 0 )); then
        print -u2 "Expected failure: $tag"
        failures=$((failures + 1))
    fi
}
run_case relative-ok ok relative success
run_case empty empty relative failure
run_case false false relative failure
run_case invalid invalid relative failure
run_case long-path ok absolute success
(( failures == 0 )) || { print -u2 "Transport contract failed: $failures; evidence: $work"; exit 1; }
print "Host request contract: 5 cases passed; evidence: $work"

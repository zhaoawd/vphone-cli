#!/bin/zsh
set -euo pipefail

root="${0:a:h:h:h:h:h}"
cd "$root"
# Development-only comparison: compile the pinned upstream admission/paging
# code with its declared methods and the current Duo catalog. No guest runs.
reference=13169405
mkdir -p "$root/.build/rpc-contract-20261115"
out=$(mktemp -d "$root/.build/rpc-contract-20261115/preflight.XXXXXXXX")
print -r -- "$out"
mkdir "$out/upstream"
for file in GuestMethodSpec.swift GuestPaging.swift GuestProcessSpawnPolicy.swift; do
    git show "$reference:VPhoneDaemon/Daemon/$file" > "$out/upstream/$file"
done
typeset -a declarations
while IFS= read -r file; do
    declarations+=("$out/upstream/${file:t}")
    git show "$reference:$file" > "$declarations[-1]"
done < <(git ls-tree -r --name-only "$reference" VPhoneDaemon/Daemon | rg '/GuestAPI[A-Za-z]+Methods\.swift$')
(( ${#declarations} > 0 ))
# Keep the upstream force-helper test doubles; use real paging/spawn policy.
git show "$reference:VPhoneDaemon/Tests/GuestAPIStub.swift" \
    | sed '/^enum GuestPaging {/,/^}/d; /^enum GuestProcessSpawnPolicy {/,/^}/d' > "$out/upstream/GuestAPIStub.swift"
{
    print 'nonisolated(unsafe) let kinds: [GuestMethodArea] = ['
    awk '/^enum [A-Za-z]+Method: String, GuestMethod \{/ { sub(/:$/, "", $2); print "    .make(" $2 ".self) { _, p in p }," }' "${declarations[@]}"
    print ']'
} > "$out/upstream/kinds.swift"
git rev-parse "$reference^{commit}" > "$out/upstream-revision.txt"
git rev-parse HEAD > "$out/duo-revision.txt"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -module-cache-path "$out/module-cache" \
    "$out/upstream/GuestMethodSpec.swift" "$out/upstream/GuestPaging.swift" \
    "$out/upstream/GuestProcessSpawnPolicy.swift" "$out/upstream/GuestAPIStub.swift" \
    "$out/upstream/kinds.swift" "${declarations[@]}" \
    VPhoneDaemon/Daemon/GuestDuoMethod.swift \
    "${0:a:h}/RPCContractPreflight.swift" -o "$out/preflight"
"$out/preflight" "$out" | tee "$out/check.log"

# Also run the pinned guest-independent upstream suite. It exercises the
# real spool/output implementation with temporary files, not guest paths.
logic="$out/reference/VPhoneDaemon/Tests/run-logic-tests.sh"
mkdir -p "${logic:h}"
git show "$reference:VPhoneDaemon/Tests/run-logic-tests.sh" > "$logic"
while IFS= read -r file; do
    target="$out/reference/VPhoneDaemon/$file"
    mkdir -p "${target:h}"
    git show "$reference:VPhoneDaemon/$file" > "$target"
done < <(sed -n 's/.*"$daemon\/\([^"]*\)".*/\1/p' "$logic")
zsh "$logic" > "$out/upstream-logic.log" 2>&1
tail -1 "$out/upstream-logic.log"

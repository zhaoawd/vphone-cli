# Kernel Info Queries

Run commands from the repository root. Read this reference for symbol-data queries and path resolution; it is not a prerequisite for source-only analysis.

## Select the Dataset

The SQLite database indexes symbol JSON files. Open it read-only so a missing database cannot silently become an empty file:

```bash
sqlite3 -readonly research/kernel_info/kernel_symbols.db ".schema kernel_symbols"
sqlite3 -readonly research/kernel_info/kernel_symbols.db \
  "select kernel_name, json_filename, json_path, json_sha256 from kernel_symbols order by kernel_name;"
```

For a release lookup (substitute `kernelcache.research.vphone600` for research):

```bash
sqlite3 -readonly research/kernel_info/kernel_symbols.db \
  "select kernel_name, json_filename, json_path, json_sha256, matched, missed, percent, total from kernel_symbols where kernel_name='kernelcache.release.vphone600';"
```

If the database is missing, `research/kernel_info/kernel_index.tsv` may provide the index metadata. Neither index contains the symbol entries themselves. `matched`, `missed`, and `percent` describe the indexed dataset, not validation of the current image or patch.

## Resolve and Verify the Symbol File

- First check the repository-local candidate for the selected kernel: `research/kernel_info/json/kernelcache.release.vphone600.bin.symbols.json` or `research/kernel_info/json/kernelcache.research.vphone600.bin.symbols.json`.
- If that file is absent, inspect the selected row's `json_filename` and `json_path`. Resolve relative paths from the repository root. An absolute path may refer to a different checkout; use it only if it exists and its dataset identity can be verified. Do not assume the original user's home directory exists or rewrite the database merely to relocate a file.
- Compare the candidate file's SHA-256 with the selected row's `json_sha256` before treating it as that indexed dataset. A mismatch means the correspondence is unverified. A matching JSON digest establishes correspondence with the index, not with an arbitrary input kernel; also check available kernel/build provenance.
- If no candidate exists, report the missing JSON and continue only with evidence available from the target binary or source. If a JSON exists without index metadata, state that its indexed identity is unverified and use it only to the extent supported by independent provenance.

This example checks the repository-local release candidate. If resolution above selects another verified path, replace `symbol_file` accordingly:

```bash
symbol_file='research/kernel_info/json/kernelcache.release.vphone600.bin.symbols.json'
if [ -f "$symbol_file" ]; then
  shasum -a 256 "$symbol_file"
else
  printf 'Symbol JSON missing: %s\n' "$symbol_file" >&2
fi
```

After checking the digest and provenance, search the resolved file with a literal fragment:

```bash
rg -n -F 'panic' "$symbol_file"
```

Address lookup likewise uses `rg -n -F` with the requested address. Check the JSON structure before interpreting matches as an exact function start or a containing-function result; an empty substring search does not establish that a symbol or function is absent from the binary.

## Source Semantics When Needed

Record the available XNU revision before using it to explain target behavior:

```bash
git -C research/reference/xnu rev-parse HEAD
rg -n -F 'function_or_symbol_fragment' research/reference/xnu/{bsd,osfmk,iokit,security}
```

Relate that revision to the target kernel version using available evidence. A source match alone does not establish that the target binary implements the same behavior. If the checkout is missing, follow the skill's missing-evidence guidance instead of fetching the latest source automatically.

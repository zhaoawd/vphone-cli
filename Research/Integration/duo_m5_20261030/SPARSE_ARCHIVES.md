# Sparse VM import reproduction and repair

## Observed failure

The historical v1.6 report described a 64 GB logical VM disk growing from
27.7 GB allocated to a dense import. A full import did not finish. This work
does not reuse that report as a successful reproduction.

The new `BundleTransferTests` reproduction uses a 16 MiB `Disk.img` with data
at the start and middle, then explicitly punches aligned holes. Extending or
seeking alone did not establish a persistent sparse input on this host.
The test requires measured sparse allocation before exporting anything.

Both `.fast` (zstd) and `.max` (xz) initially failed through the actual
`VPhoneBundleTransfer.export` / `importArchive` APIs: imported contents and
logical size matched, but the restored allocation was dense.

## Evidence

Host: Apple M5 Pro, macOS 27.0.1 (26A434), Xcode 27.1 (27A9269).
The pinned libarchive package records libarchive 3.8.9, upstream commit
`27cbc7827172698143e440801fc0ba39ccb4f1f5`.

Temporary diagnostics, captured under `.build/validation/sparse`, established:

| Experiment | Result |
| --- | --- |
| Read the source with libarchive's disk reader | Two sparse ranges were reported. |
| Read the exported GNU tar member | No sparse map was reported. |
| Enable `ARCHIVE_EXTRACT_SPARSE` alone | Both transfer modes still failed the allocation assertion. |
| Inspect the file immediately before `finish_entry` | 8,392,704 logical bytes, 16 allocated 512-byte blocks in the measured run. |
| Inspect immediately after `finish_entry` | 16,777,216 logical bytes, 32,768 allocated blocks. |
| Complete length, punch verified zero ranges, then finish metadata | Both transfer modes passed. |

The [libarchive disk writer documentation](https://github.com/libarchive/libarchive/blob/master/libarchive/archive_write_disk.3)
describes sparse extraction as zero-block scanning independent of archive
format. The [pinned disk writer implementation](https://github.com/libarchive/libarchive/blob/27cbc7827172698143e440801fc0ba39ccb4f1f5/libarchive/archive_write_disk_posix.c)
has a sizing path at entry completion when the last physical write did not
reach the declared size. The observed expansion occurs in that completion
path; the lower-level filesystem cause has not been isolated.

## Repair

`intoHostDirectory` opts into sparse extraction. The guest-volume preset and
the archive writer's GNU tar format remain unchanged.

For regular host files, extraction tracks verified zero chunks and explicit
archive gaps in the stream. Before entry completion, it writes the original
final byte through libarchive so its last write reaches the declared size,
then punches only aligned ranges known to contain zeros. Libarchive finishes
the entry afterwards, restoring permissions and timestamps. This avoids a
second disk scan. Unsupported hole punching or an entry that cannot be
reopened retains a valid dense result. Invalid block ordering disables the
optimization. Existing path validation and symlink defenses still apply.

Final regression covers both compression modes, zero and nonzero file tails,
byte identity, logical length, sparse allocation, and nanosecond mtime.
The four parameter combinations restore 16 MiB disks with 98,304 or 114,688
allocated bytes in the recorded run. Allocation is not required to equal the
source's block count because archive block boundaries can leave additional
small allocated regions.

## Reproduction command

```zsh
xcodebuild -project VPhoneKit/VPhoneKit.xcodeproj \
  -scheme VPhoneArchiveKitTests -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeArchiveTests \
  -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates \
  -only-testing:VPhoneArchiveKitTests/BundleTransferTests test
```

The final full archive suite passed 103 tests in seven suites. Temporary
`DEBUG-duo-sparse` instrumentation has been removed. Full logs and `.xcresult`
are under `.build/validation/sparse/full-regression-final2.*`.

## Full VM transfer, 2026-10-30

Candidate bundle (`a71f2360` build), stopped clone `duo-candidate-20261030`,
default export mode (zstd, no IPSW directory). Evidence:
`.build/acceptance/cases/transfer-1/`, `imported-boot-1/`, `imported-boot-2/`.

| Step | Result |
| --- | --- |
| Source `Disk.img` | 64,000,000,000 logical, 29,027,905,536 allocated bytes |
| `vm export` | 69.4 s, exit 0; archive 16 GB, SHA-256 `760875d3873736ae…` |
| `vm import --name duo-imported-20261030` | 72.1 s, exit 0 |
| Imported `Disk.img` | 64,000,000,000 logical, 28,601,794,560 allocated bytes |
| Small state | `nvram.bin`, `config.plist`, `PatchReceipt.plist`, `SEPStorage` hashes equal the source |
| Imported boots (`imported-boot-2`) | 2/2: vphoned 9 s, unlock, vphoned tap opens Settings, host tap opens Dock Safari, open-flat 2034 × 1398 with the inner display shown, closed 1398 × 2034, SpringBoard PID 37 unchanged, no new reports |

The v1.6 import of the same disk would have written all 64 GB; this one
keeps it sparse, about 1.5% below the source's allocation. Allocation was
sampled every 15 s during the import. One sample, taken at 27.95 GB of
logical length, reported 46.0 GB allocated by `du`. Free space fell from
about 95 to 62 GiB over the import, consistent with the final allocation.
That transient sample is not explained. Plan for more headroom than the
final allocation when importing on a nearly full volume. `imported-boot-1`
used an Accessibility lookup for the Home-screen taps that does not work
there; the boot checks themselves passed, and `imported-boot-2` repeats them
with fixed, screenshot-checked points.

## Limits

- A constrained-free-space transfer and a `--max` (xz) full transfer have
  not run. Byte identity of the full 64 GB disk was not compared; the
  imported boot and state hashes are the acceptance evidence.
- The baseline was not transferred in full; its dense expansion is the v1.6
  record plus the small reproduction above.
- Filesystem implementations without usable `F_PUNCHHOLE` may remain dense.
- GNU tar output still has no sparse map in the measured case. Export reads
  logical zero regions and compresses them; this repair addresses imported
  allocation, not export throughput or exact preservation of extent layout.

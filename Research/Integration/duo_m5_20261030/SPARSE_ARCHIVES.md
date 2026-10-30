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

## Limits

- No full 64 GB VM import or constrained-free-space VM transfer has run yet.
- Filesystem implementations without usable `F_PUNCHHOLE` may remain dense.
- GNU tar output still has no sparse map in the measured case. Export reads
  logical zero regions and compresses them; this repair addresses imported
  allocation, not export throughput or exact preservation of extent layout.

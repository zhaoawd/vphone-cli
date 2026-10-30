# Duo M5 integration — 2026-10-30

Scope: integrate the iPhone Duo work from `vphone-cli-up` and
`vphone-duo-m5` onto upstream-based `main`, without changing the original
worktrees. Source directories are read-only inputs. On 2026-10-30 the user
approved normal shutdown of the existing source VM; no other original-VM
modification is authorized.

- [x] Import `duo-m5-v1.4`, `duo-m5-v1.5`, and `duo-m5-v1.6` with their history.
- [x] Create isolated branch/worktree `duo-integration-20261030` at `39324ee7`.
- [x] Record source inventory and decisions for every code change.
- [x] Build and test the unmodified upstream code baseline (134 known fixture failures recorded).
- [x] Integrate display configuration and its regression tests.
- [x] Integrate the optional static-inner guest patch through the patch catalog, off in standard.
- [ ] Compare upstream fold transitions with the local previous-frame hold;
      retain upstream fixes and establish whether a local adaptation is needed.
- [x] Preserve research, probes, historical scripts/results, and maintained regression scripts with provenance.
- [x] Reproduce and repair sparse archive round-trip behavior using isolated test data; 103 archive tests pass.
- [x] Build the integrated bundle and run affected firmware-free tests; existing firmware-fixture failures match baseline.
- [x] Prepare VM A/B commands and create/verify isolated seed, baseline, and candidate copies after authorized shutdown.
- [ ] Run authorized VM acceptance; distinguish historic evidence from new runs.
- [x] Review the current prepared diff, record results and remaining approval gates; repeat after VM-driven changes if needed.

## Constraints and approval gates

- No remote push, merge into `main`, data deletion, modification of source
  repositories, additional original-machine modification, or host privilege changes.
  Present concrete commands and results before requesting any needed approval.
- Use Xcode targets and native components from the new upstream layout.
- Do not read or modify the repository-root `TODO.md`.
- Build/test artifacts stay under `.build`; tracked evidence contains summaries,
  commands, hashes, and small reproducible inputs rather than VM disks or videos.
- Existing source reports do not establish behavior on the integrated bundle.

## Current state

Source `main`: `39324ee7fcbb1d909bfa293f6188a8ef752ba734` (2.14.1).
Latest local Duo branch: `3f9a15624b438e132e81093ec8b5740cbe4facf8`.
Source code worktrees were clean at inspection. The original `vphone-cli`
worktree remains on its previous integration branch with its uncommitted files.

Current checks: CoreKit 668 passed; patch catalogue 25 passed; ArchiveKit 103
passed; FoldGuard seven passed; saved CLI display regression passed; RPC request
contract five checks passed. Native device/simulator probe builds passed and
the host CSSC probe returned six correct results. Final candidate build,
bundle admission, deep/strict signature verification, and final CLI regression
passed. Full FirmwarePatcher: 780 tests with the same 134 issue records as the
baseline, no added or removed failing names. See `validation.json` for hashes
and evidence paths.

The source history is now reachable from the integration branch through a
history-only merge whose tree was checked unchanged. No merge into `main` or
remote push has been performed.

Runtime preparation: the user approved closing `duo-m5-fold214`. The normal
CLI stop returned success; both old processes exited and lsof found no state
file readers. The seed and two isolated clones are created and verified.
Source metadata/small-state hashes were unchanged during copying; clones have
distinct disk inodes, identical SEP/NVRAM data and reset identities. No clone
has been booted or updated. Root CFW/AMFI steps await manual Terminal execution.
See `Research/Integration/duo_m5_20261030/runtime-preparation.json` and
`Regression/prepare-root.zsh` there.

Detailed evidence and change decisions:
`Research/Integration/duo_m5_20261030/README.md`.

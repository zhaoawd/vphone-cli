# Duo M5 integration — 2026-10-30

Scope: integrate the iPhone Duo work from `vphone-cli-up` and
`vphone-duo-m5` onto upstream-based `main`, without changing the original
worktrees or existing machines. Source directories are read-only inputs.

- [x] Import `duo-m5-v1.4`, `duo-m5-v1.5`, and `duo-m5-v1.6` with their history.
- [x] Create isolated branch/worktree `duo-integration-20261030` at `39324ee7`.
- [ ] Record source inventory and decisions for every code change.
- [ ] Build and test the unmodified upstream code baseline.
- [ ] Integrate display configuration and its regression tests.
- [ ] Integrate any required optional guest patches through the patch catalog.
- [ ] Compare upstream fold transitions with the local previous-frame hold;
      retain upstream fixes and establish whether a local adaptation is needed.
- [ ] Preserve research, probes, and reusable regression scripts with provenance.
- [ ] Reproduce sparse archive round-trip behavior using isolated test data.
- [ ] Build the integrated bundle and run affected firmware-free tests.
- [ ] Prepare VM A/B commands and isolated acceptance inputs.
- [ ] Run authorized VM acceptance; distinguish historic evidence from new runs.
- [ ] Review the final diff, record results and remaining approval gates.

## Constraints and approval gates

- No remote push, merge into `main`, data deletion, modification of source
  repositories, modification of existing machines, or host privilege changes.
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

Detailed evidence and change decisions:
`Research/Integration/duo_m5_20261030/README.md`.

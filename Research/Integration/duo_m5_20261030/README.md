# iPhone Duo / M5 integration, 2026-10-30

## Inputs

| Input | Ref | Commit |
| --- | --- | --- |
| Target upstream baseline | main | 39324ee7fcbb1d909bfa293f6188a8ef752ba734 |
| First local Duo branch | duo-m5-v1.4 | 5899d88256054a77095d2f6f5667316af41b09b7 |
| Local two-display work | duo-m5-v1.5 | aeffd68e0d366e3d248746084ce6bc7115839512 |
| Latest local Duo work | duo-m5-v1.6 | 3f9a15624b438e132e81093ec8b5740cbe4facf8 |
| Common ancestor of baseline and latest local work | — | 2a8ee8b06f89698ff1c4e2578a38236e0d11bbf1 |

`/Users/kolar/github/vphone-cli-up` owns the three source worktrees below
`/Users/kolar/vphone-duo-m5/src`. Its `main` matches the target baseline.
`vphone-duo-m5` itself is an experiment directory, not a Git repository.
Local experimental branches are imported into the target repository without
rewriting their history. The source repositories and run directories are inputs.

Relative to the common ancestor, the local work changes 197 files, including
32 code/build/test files. Fifteen paths overlap changes on current upstream.
These counts describe path overlap, not confirmed merge conflicts.

## Integration decisions

| Change | Source | Initial decision / verification needed |
| --- | --- | --- |
| M5 X1 compatibility and guest dual displays | Upstream and earlier local merges | Keep current upstream implementation; do not reintroduce older versions. |
| Static outer/inner display selection and configuration persistence | 5899d882 | Port as an explicit option; test config, copy/export behavior, and guest patch requirements. |
| Experimental inner display node and host multi-display knobs | a103f424, 49116af3, 3b99165c | Preserve source history and reveal notes; evaluate separately from the default fold model. |
| Experimental panel mounting and window-frame correction | c5629f5b, 78b79d0f | Compare with upstream window behavior before porting. |
| Experimental vphoned display-association injection | bf02a819 | Keep inactive unless a new reproduction establishes a requirement. |
| SpringBoard touch diagnostics | b4680ceb and subsequent trace commits | Preserve diagnostic sources and evidence without enabling them by default. |
| Optional inner cutout correction | b18c8f48, 9c8f2873 | Evaluate together with static-inner mode; catalog, gate, and test any retained patch. |
| Previous-frame hold across fold transitions | fb41cd6b | Upstream now changes panel ownership, rendering, and wake behavior. Establish an A/B reproduction before adopting a runtime change. |
| Plans, probes, and regression scripts | source plan folder and run/fold214 | Preserve provenance; parameterize machine and bundle paths for new runs. |

The latest upstream already changes the same fold transition hooks used by the
local hold, and changes how the inner display's own pages are composited.
Replacing the upstream file with the local file would remove those updates.

## Historical evidence and limits

The source record is
`duo-m5-v1.6:vphone2_M5_Duo_v1.4_2026-10-27/PLAN.md`, section 13.9.
The source folder's `MANIFEST.json` hashes were checked and all six entries
matched their files at inspection. `VALIDATION.json` explicitly covers document
structure, JSON parsing, and shell syntax; its `all_passed` is not VM acceptance.

Read-only inspection confirmed these historical logs:

- `test-fold214-VPhoneCoreKitTests.log`: 664 tests in 69 suites passed.
- `test-fold214-foldguard.log`: seven checks passed.
- `test-fold214-FirmwarePatcherTests.log`: test run failed. The source notes
  attribute 134 failures to unavailable firmware samples; classification of the
  individual failures remains to be checked.
- `run/fold214/f6/cold1/results.txt`: five successful cold boots on the v1.6
  candidate, cdhash `39c2349e0a83c687f85a8f1e08cb0df5e8d9c9b9`.
- `run/fold214/f6/hostreboot/results.txt`: two successful cold boots after a host
  restart; the first crash baseline was empty. The log includes a correction
  distinguishing inherited reports from new crashes.

Historical outstanding items: application cart/navigation continuity; injected
edge-gesture routing; successful full export/import. The source reports an
archive without sparse records and an import stopped for insufficient space.
The responsible archive operation has not yet been determined.

No historic pass is a pass for this integration branch. New results must record
source SHA, bundle hash, guest patch receipt, commands, and tested machine.

## Validation strategy

1. Build the upstream `VPhone` scheme and run owning Xcode test schemes before
   code changes; store full logs and `.xcresult` under `.build`.
2. Add tests for retained display configuration behavior, including invalid
   inputs and keeping unrelated VM configuration unchanged.
3. Run patch declaration/selection/catalog tests for optional guest changes.
4. Reproduce archive sparseness with small isolated files through the existing
   `VPhoneArchiveKitTests` framework before attempting a full VM transfer.
5. Build/sign/validate the complete candidate bundle. Prepare VM A/B acceptance
   for display model, input, folds, keyboard/focus, lock/power, cold starts,
   idle, networking, audio, snapshots, and transfer.
6. Request approval for concrete actions affecting existing machines, host
   privilege state, or the remote repository after authorized preparations.

## Progress

- Imported the three source branches and created isolated worktree.
- Read upstream `AGENTS.md` and `Skills/authoring-patch-sets/SKILL.md`.
- Implementation and new build/runtime validation have not started.

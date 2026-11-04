# Duo M5 integration — 2026-10-30

Scope: integrate the iPhone Duo work from `vphone-cli-up` and
`vphone-duo-m5` onto `duo-integration-20261030`, based on upstream `main`, without changing the original
worktrees. Source directories are read-only inputs. On 2026-10-30 the user
approved normal shutdown of the existing source VM; no other original-VM
modification is authorized.

- [x] Import `duo-m5-v1.4`, `duo-m5-v1.5`, and `duo-m5-v1.6` with their history.
- [x] Create isolated branch/worktree `duo-integration-20261030` at `39324ee7`.
- [x] Record source inventory and decisions for every code change.
- [x] Build and test the unmodified upstream code baseline (134 fixture-related issue records across 128 failed test names).
- [x] Integrate display configuration and its regression tests.
- [x] Integrate the optional static-inner guest patch through the patch catalog, off in standard.
- [x] Compare upstream fold transitions with the local previous-frame hold;
      upstream still shows 1–12 black hand-over frames. User decision
      (2026-10-30): do not adapt `fb41cd6b`; keep upstream behaviour.
- [x] Preserve research, probes, historical scripts/results, and maintained regression scripts with provenance.
- [x] Reproduce and repair sparse archive round-trip behavior using isolated test data; 103 archive tests pass.
- [x] Build the integrated bundle and run affected firmware-free tests; existing firmware-fixture failures match baseline.
- [x] Prepare VM A/B commands and create/verify isolated seed, baseline, and candidate copies after authorized shutdown.
- [x] Run authorized VM acceptance; distinguish historic evidence from new runs.
      Closed by the user 2026-10-31. Not run, accepted as uncovered: safe-area/navigation-bar assessment, F6 on the baseline bundle, a `--max` transfer, and a constrained-free-space import (`F6.md`, Not covered).
- [x] Complete isolated baseline/candidate headless smoke and native probe checks;
      preserve new diagnostic reports and remaining windowed/transfer checks.
- [x] Triage new diagnostic reports against baseline, source history and repeats.
- [x] Windowed A/B: F3 touch and edge gestures, F5 transition frames, F4 power during close (`WINDOWED.md`).
- [x] Windowed A/B: keyboard modes across folds and window frame restore (`WINDOWED.md`).
- [x] F6 on the candidate: 5 cold boots, full 64 GB export/import with imported boots, snapshot round trip, 120-minute locked idle (`F6.md`).
- [x] F2 cart and navigation continuity on KFC across folds (`F6.md`): cart, sheet and exit dialog survive inner/cover folds; PID unchanged.
- [x] Host restart: 2/2 candidate cold boots pass after re-running `vphone-escalator allow` (AMFI heap patch does not survive a restart; `F6.md`).
- [x] Network (DNS, HTTPS, host-served page) and audible audio (Safari media and Settings ringtone preview heard by the user) on the candidate (`F6.md`).
- [x] Static outer/inner and cutout on/off/on (`Regression/display-matrix.zsh`, `F6.md`): P1–P7 pass; P5 (cutout off) loses all inner taps as documented.
- [x] Move the foldable board-tree precondition before disk work in `cfw update-environment` (`db111457`; `F6.md`): root check refuses in 3 s with no disk attach. Candidate rebuilt at `ea05ba81` with it (only `vphone-cli` changed; previous bundle kept at `.build/XcodeDuo-a71f2360`).
- [x] Verify Home Screen foreground recognition, icon taps on both panels, cover hit testing, and rejection on the lit and dark Lock Screen (`ELEMENT_TAP.md`).
- [ ] Investigate and fix inner-panel Home Screen `ui.element_at` returning AX error -25202.
- [x] Verify actual 30-second Auto-Lock, Never for 333 seconds, and persistence across cold boot (`ELEMENT_TAP.md`).
- [ ] Verify an independent effective-settings rewrite by profiled within one boot.
- [ ] Open issues recorded, not pursued (`F6.md`, Open issues): KFC 登录会员 ignoring some user clicks; how app accessibility got turned on.
- [x] Review the current prepared diff, record results and remaining approval gates; repeat after VM-driven changes if needed.
      Repeated 2026-10-31 for `db111457` and `72b83eb2`: one misplaced doc comment fixed; guest scan finds no universal or nested X1 Mach-O under AccessibilityBundles (78 thin executables, all lowered with backups; 434 bundles in the shared cache).

## Constraints and approval gates

- User instruction (2026-10-30): keep all iPhone Duo work on
  `duo-integration-20261030`; do not merge it into `main`.
- User instruction (2026-11-02): repair the review findings, commit, and push
  `duo-integration-20261030` to `origin`; this supersedes the earlier no-push gate for this branch.
- No merge into `main`, data deletion, modification of source
  repositories, additional original-machine modification, or additional host privilege changes.
  Present concrete commands and results before requesting any needed approval.
- Use Xcode targets and native components from the new upstream layout.
- Do not read or modify the repository-root `TODO.md`.
- Build/test artifacts stay under `.build`; tracked evidence contains summaries,
  commands, hashes, and small reproducible inputs rather than VM disks or videos.
- Existing source reports do not establish behavior on the integrated bundle.

## Current state

Review follow-up (2026-11-02):

- [x] Reproduce plist overwrite and invisible-element selection in saved tests (25 and 3 failing assertions).
- [x] Preserve existing plists on read/parse errors and filter invisible single-display targets.
- [x] Test existing rangeMinimum removal and the auto-lock request handler (81 auto-lock checks, 236 element-tap API checks pass).
- [x] Correct verification scope, KFC status, and firmware failure counts in research docs (`REVIEW_FOLLOWUP_20261102.md`).
- [x] Run daemon regressions and the complete VPhone bundle build; bundle admission and deep/strict signature verification pass (`REVIEW_FOLLOWUP_20261102.md`).
- [x] Review the final diff and prepare the authorized current-branch commit/push. Git history and the delivery message record the resulting commit and remote verification.

The candidate/build/runtime paragraphs below describe earlier checkpoints;
they do not establish runtime acceptance of the 2026-11-02 daemon changes.

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

At the earlier integration checkpoint, the source history was reachable through
a history-only merge whose tree was checked unchanged; no merge into `main` or
remote push had been performed at that checkpoint. The 2026-11-02 instruction
above authorizes pushing the review follow-up on the integration branch.

Runtime preparation: the user approved closing `duo-m5-fold214`. The normal
CLI stop returned success; both old processes exited and lsof found no state
file readers. The seed and two isolated clones are created and verified.
Source metadata/small-state hashes were unchanged during copying; clones have
distinct disk inodes, identical SEP/NVRAM data and reset identities. No clone
had been booted or updated at that checkpoint. The user then ran the prepared
root script. Both CFW updates completed successfully, both receipts list the
same 54 Guest patches with fold display/guard enabled and inner cutout absent,
and the allowlist log contains both expected VM CDHashes. The completion
marker is dated 2026-10-30 15:29:53 Asia/Shanghai.
See `Research/Integration/duo_m5_20261030/runtime-preparation.json` and
`Regression/prepare-root.zsh` there.

Runtime checkpoint: baseline and candidate headless smoke passed six supported
rotation cases, two exact unsupported-pose errors, six fold cycles, dark-fold
locked state and stable SpringBoard/backboardd PIDs. Both passed installd
installation of five probes, six CSSC checks, eight app geometry samples and
four focus/text checks. Geometry and focus measurements match between builds.
Both copies are now normally stopped; the original remains stopped. The
original worktree status digest still matches the recorded digest. Transport
and RPC contract checks each passed five cases. No product binary changed
after build `a71f2360`.

Diagnostic triage (`DIAGNOSTICS.md`): SiriSearchFeedback is a session log;
ReportSystemMemory's libdispatch `KERN_DENIED` crash recurs near boot on both
builds and on the source VM since Oct 27; the one ExcUserFault_lsd is a
non-fatal iconservices fault not reproduced in two candidate repeats. None is
attributed to the candidate. Rotation is refused about 30 s after boot on the
baseline too; runners must wait for a settled boot.

Windowed A/B (`WINDOWED.md`): F3 tap tables are identical between builds
(80/80; inner scale 1.435/1.404, residual ≤ 0.17 pt); edge gestures match
(host and `edge: 2` 3/3 on both displays). F5: both builds show 1–12 fully
black hand-over frames (72 vs 66 total), so the `fb41cd6b` gap persists
upstream; the user chose not to adapt the hold. F4: 10/10 power-during-
close trials end on the lock screen without cover Safari frames. Keyboard
modes: 8/8 focus/text continuity in hardware and software modes on both
builds; window restore: baseline loses ~32 pt per relaunch, candidate stable.
F6 (`F6.md`): 5/5 cold boots, sparse 64 GB transfer (28.6 GB imported)
with 2/2 imported boots, snapshot round trip, and a 120-minute locked idle
with stable PIDs and no new reports. Display matrix (`F6.md`, 2026-10-31):
fold/outer/inner and cutout on/off/on/fold restored all pass; without the
cutout fix the static inner screen takes no app taps, with it 8/8 arrive,
and P7 returns to P1's geometry. The run needed the board tree copied into
the imported copy's `FirmwareOriginals` first.
See `RUNTIME.md`, `WINDOWED.md`, `F6.md` and `runtime-validation.json`.

Detailed evidence and change decisions:
`Research/Integration/duo_m5_20261030/README.md`.

## Upstream sync (2026-11-04)

- [x] Apply #804, #805 and #812 to the Duo branch and verify the full bundle, signatures and targeted regressions.
- [x] Adapt the upstream machine and storage chapters in all four languages to the current Duo branch.
- [x] Validate X1 undo migration and boot on disposable VMs.
- [x] Compare the disk footprint of the restore-tree publication step before and after #804.
- [ ] Measure the full restore pipeline's peak disk use and test host shortcut routing with Accessibility access.
- [ ] Evaluate older firmware support and the documentation site separately.

See [the sync record](Research/Integration/duo_m5_20261030/UPSTREAM_SYNC_20261104.md).

## Duo display sync (2026-11-04)

- [x] Integrate #788, #799, #800 and #801, retaining the local AX and auto-lock paths.
- [x] Verify the full bundle, device-tree and patch catalogue tests, hinge tests, and daemon regressions.
- [x] Prepare and verify two disposable VM clones and the read-only root preparation preflight.
- [x] Apply the signed bundles to the isolated guests, admit both VM binaries, and run windowed Duo regressions.
- [x] Exercise rollback on an export of the real shared cache; reproduce four unintended instruction restores.
- [x] Correct X1 undo ownership and verify both legacy conversion and already-converted logs with real cache round trips.
- [ ] Exercise the actual WDA HTTP endpoint with a running WebDriverAgentRunner.

See [the display sync record](Research/Integration/duo_m5_20261030/UPSTREAM_DISPLAY_SYNC_20261104.md).

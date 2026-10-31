# Duo M5 integration — 2026-10-30

Scope: integrate the iPhone Duo work from `vphone-cli-up` and
`vphone-duo-m5` onto `duo-integration-20261030`, based on upstream `main`, without changing the original
worktrees. Source directories are read-only inputs. On 2026-10-30 the user
approved normal shutdown of the existing source VM; no other original-VM
modification is authorized.

- [x] Import `duo-m5-v1.4`, `duo-m5-v1.5`, and `duo-m5-v1.6` with their history.
- [x] Create isolated branch/worktree `duo-integration-20261030` at `39324ee7`.
- [x] Record source inventory and decisions for every code change.
- [x] Build and test the unmodified upstream code baseline (134 known fixture failures recorded).
- [x] Integrate display configuration and its regression tests.
- [x] Integrate the optional static-inner guest patch through the patch catalog, off in standard.
- [x] Compare upstream fold transitions with the local previous-frame hold;
      upstream still shows 1–12 black hand-over frames. User decision
      (2026-10-30): do not adapt `fb41cd6b`; keep upstream behaviour.
- [x] Preserve research, probes, historical scripts/results, and maintained regression scripts with provenance.
- [x] Reproduce and repair sparse archive round-trip behavior using isolated test data; 103 archive tests pass.
- [x] Build the integrated bundle and run affected firmware-free tests; existing firmware-fixture failures match baseline.
- [x] Prepare VM A/B commands and create/verify isolated seed, baseline, and candidate copies after authorized shutdown.
- [ ] Run authorized VM acceptance; distinguish historic evidence from new runs.
- [x] Complete isolated baseline/candidate headless smoke and native probe checks;
      preserve new diagnostic reports and remaining windowed/transfer checks.
- [x] Triage new diagnostic reports against baseline, source history and repeats.
- [x] Windowed A/B: F3 touch and edge gestures, F5 transition frames, F4 power during close (`WINDOWED.md`).
- [x] Windowed A/B: keyboard modes across folds and window frame restore (`WINDOWED.md`).
- [x] F6 on the candidate: 5 cold boots, full 64 GB export/import with imported boots, snapshot round trip, 120-minute locked idle (`F6.md`).
- [x] Static outer/inner and cutout on/off/on (`Regression/display-matrix.zsh`, `F6.md`): P1–P7 pass; P5 (cutout off) loses all inner taps as documented.
- [ ] Move the foldable board-tree precondition before disk work in `cfw update-environment` (imported Duo copies lack `FirmwareOriginals`; `F6.md`).
- [x] Review the current prepared diff, record results and remaining approval gates; repeat after VM-driven changes if needed.

## Constraints and approval gates

- User instruction (2026-10-30): keep all iPhone Duo work on
  `duo-integration-20261030`; do not merge it into `main`.
- No remote push, merge into `main`, data deletion, modification of source
  repositories, additional original-machine modification, or additional host privilege changes.
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

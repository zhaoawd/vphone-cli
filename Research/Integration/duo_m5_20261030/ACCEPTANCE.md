# Pending VM acceptance

## Current state and approval scope

The user approved closing `duo-m5-fold214` on 2026-10-30. Its original CLI
performed a normal stop (SIGINT), returned success, and both launch/VM processes
exited. lsof then found no open Disk.img/SEPStorage/nvram.bin handles.

After shutdown, its disk was 64,000,000,000 logical bytes and 27,766,452,224
allocated bytes. An APFS copy-on-write seed and two new-identity clones now
exist below `.build/acceptance/machines`. The source's inode/size/mtime/ctime
and small-state hashes did not change during copying. Clone disk inodes are
distinct; SEP/NVRAM hashes match and clone identities are reset. No clone has
been updated or booted. Details: `runtime-preparation.json`.

Runtime preparation status:

1. Gracefully stopping the existing `duo-m5-fold214` VM: approved and complete.
2. Copying that stopped source into an isolated seed and creating baseline
   and candidate clones with new identities, entirely inside `.build`: complete.
3. Applying the matching bundle's offline CFW environment update to each clone.
   This requires root and temporary mounts/directories managed by CFW.
4. Allowlisting the two built `vphone-vm` binaries through `vphone-escalator`.
   This changes host AMFI admission. Non-root `status` could not read amfid.

These actions do not include deleting a source VM, rebuilding/restoring its
disk, pushing branches, or merging into `main`. The user's repository-external
modification approval gate remains in effect.

## Concrete setup after approval

Use absolute paths from `validation.json` for the final candidate, and the
preserved baseline at `.build/validation/baseline/artifacts/VPhone.bundle`.
The stop/copy/clone commands below are retained as an execution record and
must not be repeated against the existing directories. Root commands have
not run. Their reviewed wrapper verifies outer bundle CDHashes, CLI/VM binary
hashes, signatures and stopped state before invoking sudo:

```zsh
zsh /Users/kolar/github/vphone-cli/.worktrees/duo-integration-20261030/Research/Integration/duo_m5_20261030/Regression/prepare-root.zsh
```

Run it in the user's Terminal so sudo can authenticate there. `--check` runs
read-only checks without invoking sudo; that mode passed. The default run
updates only the two isolated clones and allowlists the two recorded VM
binaries. It saves logs and patch receipts and writes
`.build/acceptance/root-steps-complete.json` only if all three steps succeed.

```zsh
repo=/Users/kolar/github/vphone-cli/.worktrees/duo-integration-20261030
old_cli=/Users/kolar/github/vphone-cli-up/.build/fold214/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli
baseline="$repo/.build/validation/baseline/artifacts/VPhone.bundle"
candidate="$repo/.build/XcodeDuo/Build/Products/Debug/VPhone.bundle"
library="$repo/.build/acceptance/machines"

# Only after permission to stop the existing VM; verify stopped state before copy.
"$old_cli" vm stop duo-m5-fold214
test ! -e "$library"
mkdir -p "$library"
cp -cR /Users/kolar/.vphone/machines/duo-m5-fold214 "$library/seed"
"$candidate/Contents/MacOS/vphone-cli" vm clone seed duo-baseline-20261030 --new-identity -l "$library"
"$candidate/Contents/MacOS/vphone-cli" vm clone seed duo-candidate-20261030 --new-identity -l "$library"

# Run the root steps in the user's Terminal after reviewing their exact paths.
sudo "$baseline/Contents/MacOS/vphone-cli" cfw update-environment duo-baseline-20261030 -l "$library"
sudo "$candidate/Contents/MacOS/vphone-cli" cfw update-environment duo-candidate-20261030 -l "$library"
sudo "$candidate/Contents/MacOS/vphone-escalator" allow \
  "$baseline/Contents/MacOS/vphone-vm" "$candidate/Contents/MacOS/vphone-vm"
```

The copies are already made. Recheck available storage and clone state before
root actions; the wrapper rechecks signatures, hashes and open file handles.

## Runtime checks

Run one clone at a time using its matching CLI and `-l "$library"`.
Capture boot logs and time to vphoned. Once its socket answers:

```zsh
zsh Research/Integration/duo_m5_20261030/Regression/vm-smoke.zsh \
  "$library/duo-baseline-20261030/vphone.sock" \
  "$repo/.build/acceptance/baseline-smoke-1"
```

Repeat with the candidate socket and a new candidate evidence directory.
The script asserts RPC success, stable SpringBoard/backboardd processes, and
locked state after a fold in the dark. Geometry and screenshots are recorded
for assessment; syntax validation alone is not runtime evidence.

The remaining acceptance matrix includes:

- F0 display model and DeviceHub/RPC posture agreement.
- F2 focused-field behavior, soft/hardware keyboards, cart/navigation continuity.
- F3 both touch paths, directions, edge gestures, and coordinate error.
- F4 lock/power, folds while dark, rapid reversal, no stale unlocked content.
- F5 lit-screen transition frames separately from intentional dark/wake fades
  and app launch cards; use repeatable recording and action timestamps.
- F6 repeated cold starts, 120-minute locked idle, snapshots, full export/import
  including allocation and imported boot, then host restart when authorized.
- Networking, installd IPA installation and launch, and audible audio checks.
- Static `outer` / `inner` / `fold` changes and patch on/off/on behavior on
  disposable clones. Static-inner compatibility on the new upstream device
  tree is not yet established by this integration.

The local `fb41cd6b` hold is retained in source history. Adapting it to current
upstream hooks depends on new F5 evidence; it is not active in this candidate.
Host restart, account-dependent application checks, and any additional root
actions need their own concrete preparation before execution.

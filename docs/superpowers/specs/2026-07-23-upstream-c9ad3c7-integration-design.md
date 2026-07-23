# Upstream c9ad3c7 Integration Design

## Objective

Integrate `Lakr233/vphone-cli` through upstream commit
`c9ad3c7519894744e0ba89387856ab3b22a6db1c` while preserving this fork's 38
local-only commits and bringing the final tree into compliance with the kernel
patcher guardrails in `AGENTS.md`.

The work is performed on `codex/upstream-c9ad3c7-integration`. The existing
`main` branch and its two untracked crash-report files remain untouched.

## Scope

The upstream range contains 19 commits after the shared ancestor `f508d1d`.
One commit, `e39b4bd` (`Fix Patchless Patch Pipeline`), is already represented
by the local `5eb70e4` implementation and must not introduce a second semantic
change. The remaining 18 commits are retained.

The integration includes:

- the general temporary-directory and Patchless boot fixes;
- the complete upstream iOS 27 boot, display, app-registration, DDI, Campo,
  libxpc, FileProvider, and DSC work through `c9ad3c7`;
- upstream documentation and
  `research/0_binary_patch_comparison.md` updates;
- guardrail-compliant rewrites of the kernel patch logic introduced or enabled
  by `679d3d0`, `c22da90`, `9c1227f`, `84f4887`, `9becab4`, and `fac586a`.

The integration does not redesign unrelated local camera, location, host
control, IPA, or VM lifecycle functionality.

## Approaches Considered

### Selected: preserve upstream history, then repair the final tree

Merge the existing `merge/upstream-2026-07` integration point, merge the pinned
upstream tip, resolve overlapping local work once, and add focused follow-up
commits for guardrail compliance.

This preserves upstream ancestry and the dependency order among the iOS 27
patches. It also makes future upstream comparisons substantially easier.

### Rejected: cherry-pick only individually acceptable commits

Several userland commits depend on earlier changes to `cfw.py`,
`cfw_install.sh`, and the research comparison table. A selective replay already
demonstrated context failures at `82485d9`, so this approach would require
manually reconstructing upstream changes and obscure their provenance.

### Rejected: squash all upstream changes

A squash would produce a simpler graph but lose the mapping from observed
firmware symptoms to upstream fixes. That history is particularly valuable for
kernel and DSC research.

## Integration Sequence

1. Start from local `main` at `9118f55`.
2. Merge `merge/upstream-2026-07` at `288b56f`.
   - Preserve the local `5eb70e4` Patchless pipeline implementation.
   - Accept the effective changes from `235caa5` and `478b44a`.
3. Fetch and pin upstream commit `c9ad3c7`.
4. Merge `c9ad3c7` into the integration branch.
5. Resolve conflicts by preserving both local fork capabilities and upstream
   iOS 27 behavior. No local camera, location, automation, or idle-sleep feature
   may be dropped.
6. Rewrite noncompliant kernel patch implementation details without changing
   their upstream-visible patch IDs, gating, targets, or intended control-flow
   effects.
7. Update tests and retain the upstream research comparison entries.

## Keystone-Backed Assembly Boundary

The Swift `FirmwarePatcher` target currently has Capstone but no runtime
Keystone binding. The incoming kernel patches require address-dependent
branches and a FileProvider code cave, so fixed preassembled constants are not
sufficient.

Add a narrow SwiftPM system-library target for the already-required Homebrew
Keystone installation:

- `sources/CKeystone/module.modulemap`
- `sources/CKeystone/shim.h`
- `sources/FirmwarePatcher/ARM64/ARM64Assembler.swift`

`ARM64Assembler` owns the Keystone handle lifecycle and exposes one small
interface:

```swift
public enum ARM64Assembler {
    public static func assemble(_ source: String, at address: UInt64 = 0) throws -> Data
}
```

All newly integrated replacement instructions use this interface. Capstone
round-trip tests verify the produced instruction mnemonic, operands, and branch
target. Existing unrelated constants and patchers are outside this integration
scope.

## Semantic Matching Rules

The six kernel-related upstream changes are rewritten as follows:

- `KernelJBPatchExecPolicyKill`
  - locate `mov w0, #9; mov w1, #8` through typed Capstone operands;
  - verify the preceding `ldr wN` and forward `cbz wN` control flow;
  - assemble `b <decoded-target>` with Keystone.
- `KernelJBPatchIoucSandbox`
  - retain the failure-string xref anchor;
  - identify CBNZ and B.EQ using typed Capstone operands and decoded targets;
  - assemble the deny-to-allow branch with Keystone.
- `KernelJBPatchIomfbSwap`
  - match `cmp w2, #0x588; b.ne` semantically;
  - assemble `cmp w2, #0x6e0`;
  - treat the `IOExternalMethodDispatch` size field as data rather than an
    instruction and preserve its unique table-shape check.
- `KernelJBPatchContainerUpcall`
  - retain the containermanagerd failure-string xref;
  - verify `bl; cbz w0, target` with typed operands;
  - assemble the unconditional branch with Keystone.
- `KernelJBPatchDiskImages2`
  - retain the unique C++ signature and AssertMacros string anchors;
  - preserve the all-or-nothing notification-port allocation safety rule;
  - assemble MOV and NOP replacements with Keystone.
- `KernelJBPatchFpfsScopedOpen`
  - retain the sandbox ops-table and `p_comm` behavior;
  - express the complete 20-instruction trampoline as Keystone assembly;
  - resolve all conditional and final branch targets at the actual cave
    address;
  - Capstone-disassemble the completed cave and validate its control flow before
    emitting it.

Every patch retains unique-hit checks, `applyIOS27` gating, patch logging, and
the upstream patch ID.

## Failure Handling

- A missing or ambiguous semantic anchor returns no patch and logs the exact
  failed condition.
- Keystone assembly errors fail the patch operation; no partial instruction
  sequence is emitted.
- Multi-site changes such as DiskImages2 notification-port widening remain
  all-or-nothing.
- The FileProvider cave is emitted only after every instruction and branch
  target passes Capstone validation.
- Merge conflicts are resolved in the integration branch, never by deleting
  local-only behavior.

## Test Strategy

The implementation follows red-green-refactor:

1. Add failing tests for the runtime Keystone wrapper and Capstone round trips.
2. Add synthetic instruction-sequence tests for typed operand and branch-target
   matching.
3. Add a failing FileProvider cave test that checks the two daemon comparisons,
   allow return, and final branch to the original hook.
4. Implement the minimum assembler and patch helpers required to pass each
   test.
5. Run the complete Swift test suite and `make build`.
6. Run repository static checks proving the six rewritten patchers contain no
   inline preassembled instruction arrays or operand-string matching.
7. If a pristine compatible kernel artifact is available locally, run
   `patch-component --component kernel-jb --target-os 27` and inspect emitted
   patch records. Absence of that artifact is reported explicitly rather than
   treating unit tests as device validation.

The local kernel symbol database currently points to missing JSON files and the
XNU reference checkout is absent. Therefore symbol/address claims from upstream
remain upstream validation evidence unless those datasets are restored during
implementation.

## Success Criteria

- The integration branch contains upstream history through `c9ad3c7`.
- All 38 local-only commits remain reachable and their behavior is preserved.
- `e39b4bd` introduces no duplicate pipeline logic.
- The six kernel-related implementations satisfy the repository guardrails:
  typed Capstone matching, no operand-string matching where typed operands are
  available, no inline preassembled replacement code, and Keystone-backed
  replacement assembly.
- `research/0_binary_patch_comparison.md` contains the upstream patch entries
  and remains consistent with the final enabled patch set.
- `make build` and the complete available automated test suite pass.
- Any unperformed firmware or on-device validation is clearly identified.

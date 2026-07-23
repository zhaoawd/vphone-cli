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
- guardrail review and focused rewrites of the Swift kernel patch logic
  introduced or enabled by `679d3d0`, `c22da90`, `9c1227f`, `84f4887`,
  `9becab4`, and `fac586a`;
- explicit compliance review of the associated Python patchers
  `cfw_patch_iomfb_swapend.py`, `cfw_patch_iomfb_force_kern.py`, and
  `cfw_patch_diskimagesiod.py`.

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
2. Resolve the current `merge/upstream-2026-07` tip at execution time instead
   of trusting a design-time SHA.
   - Require the local and `origin/merge/upstream-2026-07` refs to agree, or
     stop and explain which ref is newer.
   - Verify that the selected tip contains `0dad35e`, `235caa5`, `e39b4bd`,
     and `478b44a` before merging it.
   - At the 2026-07-24 design review, both local and origin refs point to
     `288b56f`, and `0dad35e` is an ancestor of that commit.
3. Merge the verified `merge/upstream-2026-07` tip.
   - Preserve the local `5eb70e4` Patchless pipeline implementation.
   - Accept the effective changes from `235caa5` and `478b44a`.
4. Fetch and pin upstream commit `c9ad3c7`.
5. Merge `c9ad3c7` into the integration branch.
6. Resolve conflicts by preserving both local fork capabilities and upstream
   iOS 27 behavior. No local camera, location, automation, or idle-sleep feature
   may be dropped.
7. Rewrite noncompliant kernel patch implementation details without changing
   their upstream-visible patch IDs, gating, targets, or intended control-flow
   effects.
8. Update tests and retain the upstream research comparison entries.

## Computed ARM64 Encoding Boundary

The Swift side continues to use the repository's existing computed-encoding
architecture. `ARM64Encoder.swift` already handles address-dependent B, BL,
ADRP, ADD, and MOVZ instructions without embedding final instruction bytes in
patch logic. This is the established Swift equivalent of the Python patchers'
Keystone-backed helpers.

Do not add a Homebrew system-library dependency and do not change the vendored
SwiftPM dependency model. Extend `ARM64Encoder` only for instruction forms
required by the incoming patches:

- conditional branches;
- W-register immediate compares;
- X-register unsigned-offset loads and immediate adds;
- MOVK X-register immediates;
- the `mrs <Xd>, tpidr_el1` form used by the FileProvider trampoline.

Existing computed `encodeB`, `encodeMovzW`, and `encodeMovzX` functions are
reused. Existing constants such as NOP, RET, and zero-return MOV instructions
remain acceptable because they are centralized, Keystone-generated, and
Capstone round-trip tested; they are not re-spelled inside patch logic.

The 20-instruction FileProvider cave is built from named encoder calls rather
than UInt32 opcode literals. Its two conditional label fixups and final branch
are computed from the actual cave address. Capstone then round-trips the
completed sequence and verifies every mnemonic, operand, and branch target
before the patcher emits it.

## Semantic Matching Rules

The six kernel-related upstream changes are reviewed and changed where needed:

- `KernelJBPatchExecPolicyKill`
  - locate `mov w0, #9; mov w1, #8` through typed Capstone operands;
  - verify the preceding `ldr wN` and forward `cbz wN` control flow;
  - encode `b <decoded-target>` with `ARM64Encoder`.
- `KernelJBPatchIoucSandbox`
  - retain the failure-string xref anchor;
  - identify CBNZ and B.EQ using typed Capstone operands and decoded targets;
  - encode the deny-to-allow branch with `ARM64Encoder`.
- `KernelJBPatchIomfbSwap`
  - match `cmp w2, #0x588; b.ne` semantically;
  - encode `cmp w2, #0x6e0` with the new computed compare helper;
  - treat the `IOExternalMethodDispatch` size field as data rather than an
    instruction and preserve its unique table-shape check.
- `KernelJBPatchContainerUpcall`
  - retain the containermanagerd failure-string xref;
  - verify `bl; cbz w0, target` with typed operands;
  - encode the unconditional branch with `ARM64Encoder`.
- `KernelJBPatchDiskImages2`
  - retain the unique C++ signature and AssertMacros string anchors;
  - preserve the all-or-nothing notification-port allocation safety rule;
  - retain its typed Capstone matching and computed MOVZ/NOP replacements;
  - treat it as verified compliant unless integration changes invalidate its
    existing round-trip behavior.
- `KernelJBPatchFpfsScopedOpen`
  - retain the sandbox ops-table and `p_comm` behavior;
  - express the complete 20-instruction trampoline through named
    `ARM64Encoder` calls and centralized constants;
  - resolve all conditional and final branch targets at the actual cave
    address;
  - Capstone-disassemble the completed cave and validate its control flow before
    emitting it.

Every patch retains unique-hit checks, `applyIOS27` gating, patch logging, and
the upstream patch ID.

## Python Patcher Compliance

- `cfw_patch_iomfb_swapend.py` already uses typed Capstone operands for its
  call-shape anchor and `asm()` for the replacement. Preserve it unchanged
  except for conflict resolution and its existing tests.
- `cfw_patch_iomfb_force_kern.py` already uses `asm_at()` for address-dependent
  branches, but `_is_dispatch_trampoline` and its idempotence check parse
  `op_str`. Replace those checks with typed Capstone register, memory, and
  branch-target operands.
- `cfw_patch_diskimagesiod.py` uses symbol/Objective-C metadata anchors and
  centralized assembler-backed MOV/RET constants. Add a typed Capstone check
  that the located IMP has an accepted original prologue or is already patched
  before writing it; an unexpected prologue must fail closed.

## Failure Handling

- A missing or ambiguous semantic anchor returns no patch and logs the exact
  failed condition.
- A computed encoder failure or Capstone round-trip mismatch fails the patch
  operation; no partial instruction sequence is emitted.
- Multi-site changes such as DiskImages2 notification-port widening remain
  all-or-nothing.
- The FileProvider cave is emitted only after every instruction and branch
  target passes Capstone validation.
- Merge conflicts are resolved in the integration branch, never by deleting
  local-only behavior.

## Test Strategy

The implementation follows red-green-refactor:

1. Add failing tests for the new `ARM64Encoder` instruction forms and their
   Capstone round trips.
2. Add synthetic instruction-sequence tests for typed operand and branch-target
   matching.
3. Add a failing FileProvider cave test that checks the two daemon comparisons,
   allow return, and final branch to the original hook.
4. Add failing Python tests for typed IOMFB trampoline matching and
   diskimagesiod prologue/idempotence validation.
5. Implement the minimum computed encoders and patch helpers required to pass
   each test.
6. Run the complete Swift and Python test suites and `make build`.
7. Run repository static checks proving the reviewed Swift patchers contain no
   inline preassembled instruction arrays or operand-string matching and the
   Python trampoline matcher no longer parses `op_str`.
8. If a pristine compatible kernel artifact is available locally, run
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
- The reviewed Swift and Python kernel-related implementations satisfy the
  repository guardrails:
  typed Capstone matching, no operand-string matching where typed operands are
  available, no inline preassembled replacement code, and computed or
  centralized assembler-backed replacement bytes.
- `make build` gains no new Homebrew or non-vendored Swift dependency.
- `research/0_binary_patch_comparison.md` contains the upstream patch entries
  and remains consistent with the final enabled patch set.
- `make build` and the complete available automated test suite pass.
- Any unperformed firmware or on-device validation is clearly identified.

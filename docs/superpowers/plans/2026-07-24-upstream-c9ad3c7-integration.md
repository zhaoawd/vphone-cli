# Upstream c9ad3c7 Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge `Lakr233/vphone-cli` through `c9ad3c7519894744e0ba89387856ab3b22a6db1c`, preserve the local fork's behavior and history, and make the incoming Swift and Python patchers comply with the repository's typed-Capstone/computed-encoding guardrails.

**Architecture:** Preserve upstream ancestry with two merges, then repair only the final patching boundaries. Swift remains self-contained by extending `ARM64Encoder`; Python continues to use the existing Capstone/Keystone helpers. All semantic matching, branch reconstruction, and the FileProvider cave are covered by focused red-green tests before the implementation changes.

**Tech Stack:** Git, Swift 6, Swift Testing, vendored Capstone SwiftPM binding, Python 3, `unittest`, Capstone, Keystone, zsh, Make.

## Global Constraints

- Work from the committed design in `docs/superpowers/specs/2026-07-23-upstream-c9ad3c7-integration-design.md`.
- Do not read, create, or update `/TODO.md`.
- Keep the two existing untracked crash reports in the primary checkout untouched.
- Use an isolated worktree for implementation. Keep `main` at `9118f55`.
- Pin the public upstream merge to `c9ad3c7519894744e0ba89387856ab3b22a6db1c`, even if upstream `main` advances.
- Do not add a Homebrew Keystone dependency or any other SwiftPM dependency.
- Preserve upstream patch IDs, `applyIOS27` gating, targets, unique-hit checks, and control-flow effects.
- Preserve local camera, location, automation, IPA, host-control, VM lifecycle, and idle-sleep behavior.
- Do not hardcode instruction offsets, virtual addresses, or preassembled instruction bytes in patch logic.
- Keep `KernelJBPatchDiskImages2` all-or-nothing for notification-port allocation and bound widening.
- Update `research/0_binary_patch_comparison.md` for the integrated patches and the final reveal/validation record.

---

## Task 1: Create the isolated execution worktree and capture the baseline

**Files:**

- Verify only: `/Users/qcz3840/github/vphone-cli`
- Worktree: `/private/tmp/vphone-cli-upstream-c9ad3c7-worktree`

- [ ] **Step 1: Verify the primary checkout is on the design branch and has only the known untracked files**

Run:

```bash
git status --short --branch
git log --oneline -3
```

Expected:

- branch is `codex/upstream-c9ad3c7-integration`;
- commits `4f51436` and `140cbfa` are present;
- the only untracked paths are `ExcUserFault_Setup-2026-06-03-235341.ips` and `panic-full-2026-06-03-234744.0002.ips`.

- [ ] **Step 2: Release the integration branch from the primary checkout**

Run:

```bash
git switch main
git status --short --branch
```

Expected: `main` is at `9118f55`; both untracked crash reports remain listed and unchanged.

- [ ] **Step 3: Add the integration branch as an external worktree**

Run:

```bash
git worktree add /private/tmp/vphone-cli-upstream-c9ad3c7-worktree codex/upstream-c9ad3c7-integration
git worktree list
```

Expected: the new worktree is on `codex/upstream-c9ad3c7-integration` at `4f51436`.

- [ ] **Step 4: Run the pre-merge baseline in the isolated worktree**

Run from `/private/tmp/vphone-cli-upstream-c9ad3c7-worktree`:

```bash
test -x /Users/qcz3840/github/vphone-cli/.venv/bin/python3
test ! -e .venv
ln -s /Users/qcz3840/github/vphone-cli/.venv .venv
make build
swift test
.venv/bin/python3 -m unittest discover -s tests -p 'test_*.py'
git status --short
```

Expected: the worktree reuses the existing project venv through an ignored
symlink; build and available tests pass; only ignored build artifacts are
created.

- [ ] **Step 5: Record any pre-existing failure before proceeding**

If any baseline command fails, capture its full command and output in the execution notes. Do not modify production code to hide a baseline failure.

## Task 2: Merge the verified legacy integration point and pinned upstream history

**Files:**

- Merge result: repository-wide
- Verify: `sources/FirmwarePatcher/Pipeline/FirmwarePipeline.swift`
- Verify: `research/0_binary_patch_comparison.md`

- [ ] **Step 1: Resolve and verify the legacy integration tip**

Run:

```bash
git rev-parse merge/upstream-2026-07
git rev-parse origin/merge/upstream-2026-07
git merge-base --is-ancestor 0dad35e merge/upstream-2026-07
git merge-base --is-ancestor 235caa5 merge/upstream-2026-07
git merge-base --is-ancestor e39b4bd merge/upstream-2026-07
git merge-base --is-ancestor 478b44a merge/upstream-2026-07
```

Expected: the two `rev-parse` outputs agree; every ancestry check exits 0. At design review time the agreed tip was `288b56f`.

- [ ] **Step 2: Merge the verified legacy integration branch**

Run:

```bash
git merge --no-ff --no-edit merge/upstream-2026-07
git status --short
```

Expected: a merge commit is created without deleting local-only behavior.

- [ ] **Step 3: Acquire the public upstream without negotiating against the local repository**

Create a standalone shallow public clone:

```bash
git clone --no-checkout --depth=32 --single-branch --branch main https://github.com/Lakr233/vphone-cli.git /private/tmp/vphone-cli-upstream-source-20260724
```

Verify the pinned commit is present:

```bash
git -C /private/tmp/vphone-cli-upstream-source-20260724 cat-file -e c9ad3c7519894744e0ba89387856ab3b22a6db1c^{commit}
git -C /private/tmp/vphone-cli-upstream-source-20260724 cat-file -e 478b44a^{commit}
git -C /private/tmp/vphone-cli-upstream-source-20260724 merge-base --is-ancestor 478b44a c9ad3c7519894744e0ba89387856ab3b22a6db1c
```

If the depth no longer contains both commits and their ancestry, deepen the
standalone clone in increments of 32 until all three commands succeed. Do not
fetch directly from GitHub into the local repository.

- [ ] **Step 4: Import the pinned objects locally and merge the exact commit**

Run:

```bash
git fetch /private/tmp/vphone-cli-upstream-source-20260724 c9ad3c7519894744e0ba89387856ab3b22a6db1c
git cat-file -e c9ad3c7519894744e0ba89387856ab3b22a6db1c^{commit}
git merge --no-ff --no-edit c9ad3c7519894744e0ba89387856ab3b22a6db1c
git status --short
```

Expected: upstream ancestry through `c9ad3c7` is reachable. If Git reports a conflict, preserve both sides and apply these exact policies:

- keep the local `currentData` chaining and `extractPatchedData` implementation in `Pipeline/FirmwarePipeline.swift`;
- keep both local feature wiring and upstream iOS 27 patch wiring in orchestrators and install scripts;
- keep upstream additions to `research/0_binary_patch_comparison.md` and retain local comparison entries;
- never resolve a source conflict by choosing the whole file from one side.

- [ ] **Step 5: Prove the Patchless fix is present once semantically**

Run:

```bash
rg -n 'makePatcher\\(currentData|CryptexFilesystemPatcher|ManifestHashPatcher' sources/FirmwarePatcher/Pipeline/FirmwarePipeline.swift
swift test --filter chainedPatchersReceivePreviousPatchedBytes
git merge-base --is-ancestor 5eb70e4 HEAD
git merge-base --is-ancestor e39b4bd HEAD
```

Expected: patchers are chained through `currentData`; each special patched-data extraction case appears once in `extractPatchedData`; the focused test passes; both histories are reachable.

- [ ] **Step 6: Verify local-only capabilities survived the merge**

Run:

```bash
git merge-base --is-ancestor 9118f55 HEAD
rg -n 'prevent.*idle|idle.*sleep|VPhoneLocation|automation|VPhoneIPA|camera' sources scripts
git diff --check
```

Expected: local `main` is an ancestor, representative local features remain, and the merge has no whitespace errors.

## Task 3: Add durable guardrail tests before rewriting patch logic

**Files:**

- Create: `tests/test_kernel_patch_guardrails.py`

- [ ] **Step 1: Add the failing static guardrail test**

Create a `unittest.TestCase` that reads the six reviewed Swift files and three Python files. The test must reject:

```python
SWIFT_FORBIDDEN = (
    "operandString",
    "0x5280_0120",
    "0x5280_0101",
    "0x7100_0000",
    "0xD538_D088",
    "0xF941_F908",
    "0xF940_0D08",
    "0x9115_B108",
    "0xF940_0109",
    "0xEB0A_013F",
    "0xD280_0000",
    "0xD65F_03C0",
    "0x5400_0000",
    "0xF280_0000",
)

PYTHON_FORBIDDEN = (".op_str",)
```

Limit those assertions to:

```python
SWIFT_PATCHERS = (
    "KernelJBPatchExecPolicyKill.swift",
    "KernelJBPatchIoucSandbox.swift",
    "KernelJBPatchIomfbSwap.swift",
    "KernelJBPatchContainerUpcall.swift",
    "KernelJBPatchDiskImages2.swift",
    "KernelJBPatchFpfsScopedOpen.swift",
)

PYTHON_PATCHERS = (
    "cfw_patch_iomfb_swapend.py",
    "cfw_patch_iomfb_force_kern.py",
    "cfw_patch_diskimagesiod.py",
)
```

Use `Path(__file__).resolve().parents[1]` as the repository root so the test is independent of the current directory.

- [ ] **Step 2: Run the test and confirm it fails for the incoming implementations**

Run:

```bash
.venv/bin/python3 tests/test_kernel_patch_guardrails.py -v
```

Expected: failures cite operand-string parsing and inline instruction opcodes in the reviewed files.

- [ ] **Step 3: Keep the red test visible until the reviewed scope is green**

Run:

```bash
git status --short tests/test_kernel_patch_guardrails.py
```

Expected: the new test remains uncommitted while Tasks 4-7 remove each
violation. It is committed with the final Python compliance work so no commit
in the finished branch intentionally leaves this durable gate red.

## Task 4: Extend `ARM64Encoder` test-first

**Files:**

- Modify: `tests/FirmwarePatcherTests/FirmwarePatcherTests.swift`
- Modify: `sources/FirmwarePatcher/ARM64/ARM64Encoder.swift`

- [ ] **Step 1: Add failing Capstone round-trip tests**

Add these tests to `ARM64EncoderTests`:

```swift
@Test func encodeBCondEqForward() throws
@Test func encodeBCondRejectsMisalignmentAndRange()
@Test func encodeCmpImmediateW() throws
@Test func encodeCmpRegisterX() throws
@Test func encodeLdrImmediateX() throws
@Test func encodeLdrImmediateXRejectsUnscaledOffset()
@Test func encodeMovkX() throws
@Test func encodeMrsTpidrEl1() throws
```

Use Capstone detail operands, not rendered operand strings, to assert:

- `b.eq` from `0x1000` reaches `0x1080`;
- `cmp w2, #0x6e0` has register `w2` and immediate `0x6e0`;
- `cmp x9, x10` has registers `x9` and `x10`;
- `ldr x8, [x8, #0x3f0]` has destination/base `x8` and displacement `0x3f0`;
- `movk x10, #0x6f73, lsl #16` targets `x10`;
- `mrs x8, tpidr_el1` decodes as `mrs` and writes `x8`.

- [ ] **Step 2: Run the encoder tests and verify the missing API failures**

Run:

```bash
swift test --filter ARM64EncoderTests
```

Expected: compilation fails because the new encoder methods and condition type do not exist.

- [ ] **Step 3: Implement only the required computed encoders**

Add to `ARM64Encoder`:

```swift
public enum Condition: UInt32 {
    case eq = 0
    case ne = 1
}

public static func encodeBCond(
    _ condition: Condition,
    from pc: Int,
    to target: Int
) -> Data?

public static func encodeCmpImmediateW(rn: UInt32, imm12: UInt32) -> Data?
public static func encodeCmpRegisterX(rn: UInt32, rm: UInt32) -> Data
public static func encodeLdrImmediateX(rt: UInt32, rn: UInt32, offset: UInt32) -> Data?
public static func encodeMovkX(rd: UInt32, imm16: UInt16, shift: UInt32 = 0) -> Data?
public static func encodeMrsTpidrEl1(rd: UInt32) -> Data
```

Each method must:

- validate alignment, range, shift, or scaled-offset constraints;
- mask register indices to five bits;
- construct the instruction from named ISA fields;
- return little-endian bytes through `ARM64.encodeU32`.

Reuse the existing `encodeAddImm12`, `encodeMovzX`, `encodeB`, `ARM64.ret`, and `ARM64.nop`; do not create duplicate helpers.

- [ ] **Step 4: Run the focused and full Swift tests**

Run:

```bash
swift test --filter ARM64EncoderTests
swift test
```

Expected: all tests pass.

- [ ] **Step 5: Commit the encoder boundary**

Run:

```bash
git add sources/FirmwarePatcher/ARM64/ARM64Encoder.swift tests/FirmwarePatcherTests/FirmwarePatcherTests.swift
git commit -m "feat: extend computed ARM64 encoders"
```

## Task 5: Convert the four branch/compare patchers to typed Capstone matching

**Files:**

- Modify: `sources/FirmwarePatcher/Kernel/JBPatches/KernelJBPatchExecPolicyKill.swift`
- Modify: `sources/FirmwarePatcher/Kernel/JBPatches/KernelJBPatchIoucSandbox.swift`
- Modify: `sources/FirmwarePatcher/Kernel/JBPatches/KernelJBPatchIomfbSwap.swift`
- Modify: `sources/FirmwarePatcher/Kernel/JBPatches/KernelJBPatchContainerUpcall.swift`
- Verify: `sources/FirmwarePatcher/Kernel/JBPatches/KernelJBPatchDiskImages2.swift`
- Modify: `sources/FirmwarePatcher/ARM64/ARM64Disassembler.swift`
- Modify tests: `tests/FirmwarePatcherTests/FirmwarePatcherTests.swift`

- [ ] **Step 1: Add synthetic typed-operand helper tests**

Add a `KernelPatchSemanticInstructionTests` suite that constructs input
instructions with `ARM64Encoder` where available and test-only computed fixture
builders for source CBZ/CBNZ/W-LDR forms that the patchers never emit.
Disassemble them with `ARM64Disassembler` and check typed helpers for:

- `mov/movz w0,#9; mov/movz w1,#8`;
- same-register `ldr wN; cbz wN,target`;
- `cbnz wN,target` and `b.eq target`;
- `cmp w2,#0x588; b.ne target`;
- `bl target; cbz w0,target`.

Extend `ARM64Disassembler` with:

```swift
public func registerName(at index: Int, in instruction: Instruction) -> String?
public func immediate(at index: Int, in instruction: Instruction) -> Int64?
public func memoryBaseRegisterName(at index: Int, in instruction: Instruction) -> String?
```

These helpers must read `insn.aarch64?.operands`, `AARCH64_OP_REG`,
`AARCH64_OP_IMM`, and `AARCH64_OP_MEM`. They must bounds-check operand indices
and must not inspect `operandString`.

- [ ] **Step 2: Run the new tests and confirm they fail**

Run:

```bash
swift test --filter KernelPatchSemanticInstructionTests
```

Expected: compilation fails until the typed helper surface is added.

- [ ] **Step 3: Rewrite `KernelJBPatchExecPolicyKill`**

Replace raw `movz` opcode comparisons and `operandString.hasPrefix` checks with typed Capstone checks. Read the CBZ target from its immediate operand and require:

- the reason pair is exactly W0/9 then W1/8;
- the LDR destination and CBZ tested register are the same W register;
- the target is forward and skips the reason-create block.

Continue emitting `ARM64Encoder.encodeB(from:to:)` under patch ID `exec_security_policy_kill`.

- [ ] **Step 4: Rewrite `KernelJBPatchIoucSandbox`**

Delete `isCbnzW`, `cbTarget`, and `bCondEqTarget`. Decode CBNZ and B.EQ through Capstone detail operands and require:

- CBNZ's first operand is a W register;
- its target encloses the failure-string ADRP;
- the nearby conditional instruction is `b.eq`;
- both targets remain inside the pinned function.

Continue emitting a computed unconditional B under patch ID `iouc_sandbox_gate`.

- [ ] **Step 5: Rewrite `KernelJBPatchIomfbSwap`**

Match `cmp w2,#0x588; b.ne` through typed operands. Replace the compare with:

```swift
ARM64Encoder.encodeCmpImmediateW(rn: 2, imm12: Self.swapEndIOS27Size)
```

Keep `checkStructureInputSize` as table data and retain its pointer/table-shape uniqueness check. Preserve patch IDs `iomfb_swapend_handler_size` and `iomfb_swapend_variable_size`.

- [ ] **Step 6: Rewrite `KernelJBPatchContainerUpcall`**

Require the string-xref predecessor sequence to be typed `bl; cbz w0,target`. Read the CBZ target from the immediate operand, require a backward executable target, and emit `ARM64Encoder.encodeB`. Preserve patch ID `container_manager_upcall_force_success`.

- [ ] **Step 7: Verify `KernelJBPatchDiskImages2` without changing behavior**

Confirm it still uses typed Capstone operands, `ARM64Encoder.encodeMovzW/X`, and centralized `ARM64.nop`. Run:

```bash
rg -n 'operandString|0x[0-9A-Fa-f_]{8}' sources/FirmwarePatcher/Kernel/JBPatches/KernelJBPatchDiskImages2.swift
```

Expected: no operand-string matcher and no inline instruction opcode. Semantic sizes/field displacements may remain because they are data/structure anchors.

- [ ] **Step 8: Run focused tests and the static gate**

Run:

```bash
swift test --filter KernelPatchSemanticInstructionTests
.venv/bin/python3 tests/test_kernel_patch_guardrails.py -v
```

Expected: semantic tests pass; the static test now fails only on the FileProvider cave and Python matcher work left for later tasks.

- [ ] **Step 9: Commit the semantic matcher rewrite**

Run:

```bash
git add sources/FirmwarePatcher/Kernel/JBPatches/KernelJBPatchExecPolicyKill.swift
git add sources/FirmwarePatcher/Kernel/JBPatches/KernelJBPatchIoucSandbox.swift
git add sources/FirmwarePatcher/Kernel/JBPatches/KernelJBPatchIomfbSwap.swift
git add sources/FirmwarePatcher/Kernel/JBPatches/KernelJBPatchContainerUpcall.swift
git add sources/FirmwarePatcher/ARM64/ARM64Disassembler.swift
git add tests/FirmwarePatcherTests/FirmwarePatcherTests.swift
git commit -m "refactor: use typed kernel patch matching"
```

## Task 6: Rebuild and validate the FileProvider trampoline

**Files:**

- Modify: `sources/FirmwarePatcher/Kernel/JBPatches/KernelJBPatchFpfsScopedOpen.swift`
- Modify: `tests/FirmwarePatcherTests/FirmwarePatcherTests.swift`

- [ ] **Step 1: Add a failing 20-instruction cave round-trip test**

Make `buildScopedOpenCave(caveOff:realHookOff:)` internal so `@testable import FirmwarePatcher` can call it. Instantiate `KernelJBPatcher(data: Data(repeating: 0, count: 0x4000), verbose: false)` and build a cave at `0x1000` targeting `0x3000`.

Assert:

- the result is exactly 80 bytes / 20 instructions;
- mnemonics are `mrs, ldr, ldr, add, ldr`, four MOVZ/MOVK instructions, `cmp`, `b.eq`, four MOVZ/MOVK instructions, `cmp`, `b.eq`, `mov`, `ret`, `b`;
- both B.EQ operands target the final B instruction;
- the final B operand targets `0x3000`;
- X9 is compared against X10 in both compare instructions;
- the allow path writes X0 with zero before RET.

- [ ] **Step 2: Run the cave test and confirm it exposes the literal implementation**

Run:

```bash
swift test --filter FpfsScopedOpenCaveTests
```

Expected: the test fails until the builder is accessible and returns a fully validated computed sequence.

- [ ] **Step 3: Replace every inline cave opcode**

Build the sequence by appending only:

- `ARM64Encoder.encodeMrsTpidrEl1`;
- `ARM64Encoder.encodeLdrImmediateX`;
- `ARM64Encoder.encodeAddImm12`;
- `ARM64Encoder.encodeMovzX`;
- `ARM64Encoder.encodeMovkX`;
- `ARM64Encoder.encodeCmpRegisterX`;
- `ARM64Encoder.encodeBCond`;
- `ARM64Encoder.encodeB`;
- centralized `ARM64.ret`.

Represent `"Resolver"` and `"fileprov"` as four `UInt16` chunks each. Those chunks are semantic string data, not preassembled instructions.

- [ ] **Step 4: Validate the completed cave before either emit**

Disassemble all 80 bytes at the actual `caveOff` and verify the same register, immediate, mnemonic, and branch-target invariants as the test. Return `nil` on any mismatch. In `patchFpfsScopedVnodeOpen`, compute and validate both `caveBytes` and `newEntry` before calling either `emit`.

- [ ] **Step 5: Run cave, encoder, and static tests**

Run:

```bash
swift test --filter FpfsScopedOpenCaveTests
swift test --filter ARM64EncoderTests
.venv/bin/python3 tests/test_kernel_patch_guardrails.py -v
```

Expected: Swift tests pass; the static gate now fails only for the Python `op_str` matcher.

- [ ] **Step 6: Commit the cave rewrite**

Run:

```bash
git add sources/FirmwarePatcher/Kernel/JBPatches/KernelJBPatchFpfsScopedOpen.swift
git add tests/FirmwarePatcherTests/FirmwarePatcherTests.swift
git commit -m "refactor: compute FileProvider trampoline instructions"
```

## Task 7: Bring the three Python patchers into explicit compliance

**Files:**

- Verify: `scripts/patchers/cfw_patch_iomfb_swapend.py`
- Modify: `scripts/patchers/cfw_patch_iomfb_force_kern.py`
- Modify: `scripts/patchers/cfw_patch_diskimagesiod.py`
- Create: `tests/test_cfw_patch_semantics.py`

- [ ] **Step 1: Add failing typed IOMFB trampoline tests**

In `tests/test_cfw_patch_semantics.py`, add a fake chunk reader and assemble:

```python
sequence = (
    asm_at("cbz x0, #0x1040", 0x1000)
    + asm("ldr x8, [x0, #0x28]")
    + asm_at("cbz x8, #0x1040", 0x1008)
    + asm("braaz x8")
)
```

Assert `_is_dispatch_trampoline` accepts it. Add negative cases where:

- the LDR base is X1;
- the second CBZ tests a register other than the LDR destination;
- the terminal branch uses a different register.

Add an idempotence helper test proving a typed unconditional-B immediate equals the expected `_kern_*` VA.

- [ ] **Step 2: Add failing diskimagesiod prefix tests**

Add tests for a new `_classify_imp_prefix(data, offset)` helper:

- `MOV_X0_1 + RET` returns `"already-patched"`;
- `asm("pacibsp") + asm("stp x29, x30, [sp, #-0x10]!")` returns `"patchable"`;
- an unrelated `nop; nop` prefix returns `"unexpected"`;
- truncated data returns `"unexpected"`.

- [ ] **Step 3: Run the Python semantic tests and verify they fail**

Run:

```bash
.venv/bin/python3 tests/test_cfw_patch_semantics.py -v
```

Expected: missing typed helper/classifier failures.

- [ ] **Step 4: Rewrite `cfw_patch_iomfb_force_kern.py` with typed operands**

Import `ARM64_OP_REG`, `ARM64_OP_IMM`, and `ARM64_OP_MEM`. Validate:

- first CBZ operand register is X0;
- LDR destination is an X register and its memory base is X0;
- second CBZ tests the same destination register;
- BRAAZ/BRAA/BR uses that same register;
- an already-patched B has one immediate operand equal to `kern_va`.

Keep `asm_at(f"b #{kern_va}", pub_va)` for replacement bytes. Remove all `.op_str` parsing; log symbol names and addresses instead of rendered operands.

- [ ] **Step 5: Fail closed in `cfw_patch_diskimagesiod.py`**

Before writing:

```python
state = _classify_imp_prefix(data, imp_foff)
if state == "already-patched":
    print("  [=] isMountComplete already returns YES")
    return True
if state != "patchable":
    print("  [-] Unexpected IMP prologue; refusing to patch")
    return False
```

Implement the classifier with `_cs.detail` operands. Accept only the known signed-frame prologue families (`pacibsp`/`paciasp` followed by frame setup, or a frame-setup `stp`/`sub` first instruction). Keep centralized Keystone-backed `MOV_X0_1` and `RET`.

Import `_cs` explicitly from `.cfw_asm`; wildcard imports do not import
underscore-prefixed names.

- [ ] **Step 6: Verify `cfw_patch_iomfb_swapend.py` remains compliant**

Run its self-test:

```bash
PYTHONPATH=scripts .venv/bin/python3 scripts/patchers/cfw_patch_iomfb_swapend.py
```

Expected: `self-test OK`. Do not rewrite its typed `_mov_reg_imm` matcher or `asm()` replacement.

- [ ] **Step 7: Run all Python tests and the durable guardrail gate**

Run:

```bash
.venv/bin/python3 tests/test_cfw_patch_semantics.py -v
.venv/bin/python3 tests/test_kernel_patch_guardrails.py -v
.venv/bin/python3 -m unittest discover -s tests -p 'test_*.py'
```

Expected: all pass.

- [ ] **Step 8: Commit the Python compliance work**

Run:

```bash
git add scripts/patchers/cfw_patch_iomfb_force_kern.py
git add scripts/patchers/cfw_patch_diskimagesiod.py
git add tests/test_cfw_patch_semantics.py
git add tests/test_kernel_patch_guardrails.py
git commit -m "refactor: type-check CFW patch anchors"
```

## Task 8: Document final patch provenance and validation limits

**Files:**

- Modify: `research/0_binary_patch_comparison.md`
- Verify: `docs/superpowers/specs/2026-07-23-upstream-c9ad3c7-integration-design.md`

- [ ] **Step 1: Reconcile the comparison table with the enabled patch set**

For each incoming patch, record:

- upstream commit and retained patch ID;
- source/string/metadata anchor;
- typed Capstone validation shape;
- computed/Keystone-backed replacement;
- `applyIOS27` or CFW phase gating;
- expected no-op or fail-closed behavior on other versions.

Cover ExecPolicyKill, IOUC Sandbox, IOMFB swap handler/dispatch, ContainerUpcall, DiskImages2, FPFS scoped open, force-kern DSC, SwapEnd DSC, and diskimagesiod.

- [ ] **Step 2: Record reveal and validation evidence**

State explicitly that:

- the local kernel symbol database points to missing JSON files;
- the XNU reference checkout is absent;
- source/address claims inherited from upstream were not independently symbolicated locally;
- semantic decode, unit, integration, firmware, and on-device validation are distinct levels.

- [ ] **Step 3: Verify documentation and code agree**

Run:

```bash
rg -n 'exec_security_policy_kill|iouc_sandbox_gate|iomfb_swapend|container_manager_upcall|di2_|fpfs_scoped_open' sources research/0_binary_patch_comparison.md
git diff --check
```

Expected: every enabled patch ID is represented and no stale Keystone/Homebrew claim remains.

- [ ] **Step 4: Commit the research update**

Run:

```bash
git add research/0_binary_patch_comparison.md
git commit -m "docs: record upstream patch integration evidence"
```

## Task 9: Run the complete verification matrix and review the final history

**Files:**

- Verify only: repository-wide

- [ ] **Step 1: Run static and unit gates**

Run:

```bash
.venv/bin/python3 tests/test_kernel_patch_guardrails.py -v
.venv/bin/python3 -m unittest discover -s tests -p 'test_*.py'
swift test
git diff --check
```

Expected: all pass.

- [ ] **Step 2: Build and sign through the supported entry point**

Run:

```bash
make build
```

Expected: release build and codesign succeed without installing a new dependency.

- [ ] **Step 3: Run available firmware fixtures**

Inventory local artifacts first:

```bash
swift test --filter PatchComparisonTests
rg --files ipsws | rg '/kernelcache\\.research\\.vphone600$'
```

If at least one pristine local kernel is listed, run:

```bash
make test_jb_patches QUICK=1
make test_fw_patches QUICK=1
```

Expected:

- local fixtures pass;
- quick kernel/full-firmware gates pass when compatible local artifacts exist;
- if artifacts are absent, preserve the exact skip/error output and report the limitation instead of claiming firmware validation.

- [ ] **Step 4: Inspect patch records for an available iOS 27 kernel**

If a pristine compatible kernel exists locally, run the patcher with `--component kernel-jb --target-os 27` using the command form printed by `tests/test_jb_kernel_patches.sh`, and verify one record for every retained patch ID. Do not download a kernel unless network access is separately authorized.

- [ ] **Step 5: Audit ancestry, scope, and local-feature preservation**

Run:

```bash
git merge-base --is-ancestor 9118f55 HEAD
git merge-base --is-ancestor 288b56f HEAD
git merge-base --is-ancestor c9ad3c7519894744e0ba89387856ab3b22a6db1c HEAD
git log --graph --decorate --oneline --max-count=40
git status --short
git diff 9118f55..HEAD --stat
```

Expected: all ancestry checks exit 0, the graph contains both merge lines, the worktree is clean, and the diff contains the upstream iOS 27 work plus focused guardrail/test/research follow-ups.

- [ ] **Step 6: Request a code review before integration handoff**

Use `superpowers:requesting-code-review` to review:

- history preservation and conflict resolution;
- encoder correctness and bounds;
- typed operand matching and uniqueness;
- FPFS cave all-or-nothing validation;
- Python idempotence/fail-closed behavior;
- test and firmware-validation evidence.

- [ ] **Step 7: Address review findings and rerun affected gates**

For every accepted finding, add a focused failing test, implement the minimal fix, rerun the focused and full relevant suites, and commit with a descriptive message.

- [ ] **Step 8: Finish the development branch**

Use `superpowers:finishing-a-development-branch` and present the verified integration branch for merge/PR/retention. Do not push or open a PR unless the user explicitly requests it.

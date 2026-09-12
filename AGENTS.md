# vphone-cli

Virtual iPhone boot tool using Apple's Virtualization.framework with PCC research VMs.

## Build and Validation

- **Platform:** macOS 15+, Swift 6.0 (SwiftPM); VM execution requires SIP/AMFI disabled.
- **VM build:** `make build` builds and signs the app with private entitlements. A plain `swift build` output is insufficient for VM execution.
- **Offline patcher build:** `make patcher_build` builds the unsigned CLI used by firmware patch targets; it does not boot a VM.
- **Boot:** `make boot` (GUI), `make boot_dfu` (DFU). Use `make help` for targets and options.
- **Python:** Use the project `.venv`; create it with `make setup_venv`, then activate with `source .venv/bin/activate`. Dependencies are in `requirements.txt`.

Choose validation for the changed behavior:

| Command | Scope |
| --- | --- |
| `make test_python` / `make test_swift` | Firmware-free tests for one language |
| `make test` | Both firmware-free suites |
| `make test_fixtures` | Fixture presence check only; no tests run |
| `make test_firmware` | Swift firmware comparisons; requires complete fixtures at `VPHONE_TEST_FIXTURES` or `ipsws/patch_refactor_input` |

The test entrypoint is `scripts/run_tests.py`. Its Swift runner clears real-firmware acceptance selectors and separates `FirmwareIntegrationTests` from the fast suite. These targets do not boot a VM. Firmware comparison success does not establish restore, boot, or application behavior.

## Workflow Rules

- Do not create, read, or update the repository-root `TODO.md`; ignore it if present. Track relevant progress, assumptions, blockers, and next actions in current research docs, commit history, or code comments when warranted.
- When applying new patches, also update `research/0_binary_patch_comparison.md`.
- Complete the requested implementation and relevant validation, fix failures caused by the change, and rerun affected checks within the authorized scope without asking for approval at each step. Include real VM acceptance when the task requests it. Report environmental blockers and unverified behavior explicitly.
- Read references for the current task. The July 2026 `upstream-c9ad3c7-integration` design and plan under `docs/superpowers/` describe that integration; their historical branch, skill, and execution requirements do not apply to unrelated work.
- For `vphone600` symbol lookup, kernel reverse engineering, or kernel patch analysis, read `skills/kernel-analysis-vphone600/SKILL.md`. Other kernel targets require their own evidence; do not apply the vphone600 dataset to them.

## Module and Reference Index

Use `Package.swift` for Swift targets and dependencies.

| Path | Responsibility / when to read |
| --- | --- |
| `sources/vphone-cli/` | CLI commands, VM lifecycle, AppKit/SwiftUI UI, host control, and guest client |
| `sources/VPhoneCore/` | Shared VM library, resources, process execution, locking, and restore operations |
| `sources/FirmwarePatcher/` | Swift firmware pipeline, binary handling, and boot-chain/kernel patchers |
| `scripts/patchers/` | Python CFW patchers; entrypoint `cfw.py` |
| `scripts/vphoned/` | Objective-C guest daemon; vsock port 1337, length-prefixed JSON |
| `tests/` | Python and Swift tests; Swift targets are declared in `Package.swift` |
| `research/firmware_manifest_and_origins.md` | Firmware composition and component origins |
| `research/0_binary_patch_comparison.md` | Patch scope, variant comparisons, and dated validation evidence |
| `research/host_control_protocol_e1_2026-09-11.md` | Host-control protocol and E1 validation record; implementation in `VPhoneHostControl.swift` |

## Firmware Variants

| Variant | Firmware / CFW targets |
| --- | --- |
| Regular | `fw_patch` / `cfw_install` |
| Development | `fw_patch_dev` / `cfw_install_dev` |
| Jailbreak | `fw_patch_jb` / `cfw_install_jb` |
| Experimental | `fw_patch_exp` / `cfw_install_exp` |

`fw_patch_less` is the separate less pipeline; consult `make help` and `sources/FirmwarePatcher/Pipeline/FirmwarePipeline.swift` when working on it. Patch counts depend on version and options; use the patch comparison document's dated evidence for a specific combination.

JB first-boot finalization runs via `/cores/vphone_jb_setup.sh`; monitor `/var/log/vphone_jb_setup.log`. EXP extends JB with kernel and DSC identity changes while retaining VM graphics and compute paths. Keep EXP-specific changes scoped to EXP. Host-mount CFW installation requires the VM to be off and re-executes with sudo.

## Coding Conventions

### Swift

- **Language:** Swift 6.0 (strict concurrency).
- **Style:** Pragmatic, minimal. No unnecessary abstractions.
- **Sections:** Use `// MARK: -` to organize code within files.
- **Access control:** Default (internal). Only mark `private` when needed for clarity.
- **Concurrency:** `@MainActor` for VM and UI classes. `nonisolated` delegate methods use `MainActor.isolated {}` to hop back safely.
- **Naming:** Types are `VPhone`-prefixed. Match Apple framework conventions.
- **Private APIs:** Use `Dynamic()` for runtime method dispatch from Swift, without an ObjC bridge. Touch objects use `NSClassFromString` + KVC to avoid designated initializer crashes.
- **NSWindow `isReleasedWhenClosed`:** Always set `window.isReleasedWhenClosed = false` for programmatically created windows managed by an `NSWindowController`. The default `true` causes `objc_release` crashes on dangling pointers during CA transaction commit.

### Shell Scripts

- Use `zsh` with `set -euo pipefail`.
- Scripts resolve their own directory via `${0:a:h}` or `$(cd "$(dirname "$0")" && pwd)`.

### Kernel patcher guardrails

- For kernel patchers, never hardcode file offsets, virtual addresses, or preassembled instruction bytes inside patch logic.
- All instruction matching must be derived from Capstone decode results (mnemonic / operands / control-flow), not exact operand-string text when a semantic operand check is possible.
- Python replacement instructions must use existing Keystone-backed helpers (for example `asm(...)`, `NOP`, `MOV_W0_0`). Swift replacements must use `ARM64Encoder` and centralized `ARM64` constants in `sources/FirmwarePatcher/ARM64/`; extend those helpers when needed. Keep raw instruction encodings out of patch logic.
- Prefer source-backed semantic anchors: in-image symbol lookup, string xrefs, local call-flow, and XNU correlation. Do not depend on repo-exported per-kernel symbol dumps at runtime.
- When retargeting a patch, write the reveal procedure and validation steps into the relevant research doc or commit notes before handing off for testing.
- For `patch_bsd_init_auth` specifically, the allowed reveal flow is: recover `bsd_init` -> locate rootvp panic block -> find the unique in-function `call` -> `cbnz w0/x0, panic` -> `bl imageboot_needed` site -> patch the branch gate only.
- Log each patch with its offset and before/after state.

## Design System

- **Audience:** Security researchers. Terminal-adjacent workflow.
- **Feel:** Research instrument — precise, informative, no decoration.
- **Palette:** Dark neutral (`#1a1a1a` bg), status green/amber/red/blue accents.
- **Typography:** System monospace (SF Mono / Menlo) for UI and log output.
- **Depth:** Flat with 1px borders (`#333333`). No shadows.
- **Spacing:** 8px base unit, 12px component padding, 16px section gaps.

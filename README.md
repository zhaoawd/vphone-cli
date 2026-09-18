<div align="right"><strong><a href="./docs/README_ko.md">🇰🇷한국어</a></strong> | <strong><a href="./docs/README_ja.md">🇯🇵日本語</a></strong> | <strong><a href="./docs/README_zh.md">🇨🇳中文</a></strong> | <strong>🇬🇧English</strong></div>

# vphone-cli

Boot a virtual iPhone via Apple's Virtualization.framework using PCC research VM infrastructure.

![poc](./docs/demo.jpeg)

## Prerequisites

**Host:**

- Apple Silicon
- macOS 15+ (Sequoia)
- Xcode + iOS SDK (cross-compiles the guest daemon)
- [SIP/AMFI relaxation to allow private PV=3 entitlements with unsigned-binary](#sipamfi-relaxation)

**Dependencies:**

```bash
brew install python@3.13 aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone cmake libusb ipsw zstd
```

## Install

```bash
brew install zqxwce/tap/vphone-cli
```

## Build

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git

./scripts/setup_tools.sh      # install deps, build toolchain submodules, create the Python venv
./scripts/build.sh            # build + sign vphone-cli, bundle the .app, cross-compile vphoned

cd .build/vphone-cli.app/Contents/MacOS/
vphone-cli --help
```

## Quick Start

One command creates a VM end-to-end (download → patch → DFU restore → CFW install → first boot):

```bash
vphone-cli vm create myphone -V jb        # -V / --variant

vphone-cli vm launch myphone
```

## Commands

`vphone-cli vm create` runs the whole pipeline; the individual steps below let you drive it manually or re-run one stage.

### Manage

```bash
vphone-cli vm list                         # list VMs (--json for scripting)
vphone-cli vm info myphone                  # show one VM
vphone-cli vm new myphone                   # create an empty bundle (cpu/mem/disk options)
vphone-cli vm config myphone --cpu 8 --memory 8192
vphone-cli vm clone myphone myphone-2       # fast APFS clone, fresh device identity
vphone-cli vm export myphone --out myphone.tzst   # zstd fast by default (--max = xz -9); --out may be a dir (auto-names <vm>.tzst/.txz); skips restore dir + staging files
vphone-cli vm import myphone.tzst --name restored
vphone-cli vm rename myphone iphone16
vphone-cli vm delete iphone16
```

### Build a VM manually (what `vm create` automates)

```bash
vphone-cli vm new myphone                              # 1. empty bundle
vphone-cli fw prepare myphone --iphone-version 26.1     # 2. download + merge IPSWs
vphone-cli fw patch myphone --variant jb                # 3. patch the boot chain

vphone-cli vm launch myphone --dfu &                    # 4. boot into DFU (background)
vphone-cli restore myphone --get-shsh                   #    fetch SHSH
vphone-cli restore myphone                              #    DFU restore
vphone-cli vm stop myphone                              #    stop the DFU boot

vphone-cli cfw install myphone --variant jb             # 5. install CFW (host-mount; asks for sudo)
vphone-cli vm launch myphone                            # 6. first boot
```

Update to a newer iOS by pointing `fw prepare` at an IPSW: `--iphone-source /path/to.ipsw --cloudos-source /path/to.ipsw`.

## Recovery

- `vphone-cli doctor [<name>]` — read-only diagnostics of the host and, with a VM name, that VM (files, locks, firmware transaction, restore state, create checkpoint, host control channel). Nothing is repaired; `--json` emits machine-readable output.
- `vphone-cli vm stop <name> --force` — skip the graceful shutdown request and SIGKILL the boot process immediately.
- `vphone-cli fw patch <name> --recover` — recover an interrupted firmware transaction without patching (reports the recovered archive, or that there is no pending transaction).
- `vphone-cli vm create --resume <name>` — continue an interrupted `vm create` from its checkpoint; `vphone-cli vm create-status <name>` prints the checkpoint without changing anything.

Offline bundle operations (`fw prepare`/`fw patch`, `cfw install`, `vm export`/`vm import`, `vm clone`/`vm rename`/`vm delete`) take a per-VM directory lock and refuse a busy VM (a running VM, or another offline operation holding the bundle). There is no separate command for this guard.

## Firmware Variants

Five patch variants with increasing security bypass — pass one to `--variant`:

| Variant      | Boot Chain  | CFW       | Notes                                                              |
| ------------ | ----------- | --------- | ----------------------------------------------------------------- |
| `less`       | 4 patches   | 2 phases  | Patchless — keeps iOS mitigations enabled                         |
| `regular`    | 42 patches  | 10 phases | AMFI/SSV/Img4/TXM bypass                                           |
| `dev`        | 53 patches  | 12 phases | + TXM entitlement/debug bypass                                    |
| `jb`         | 113 patches | 14 phases | + full jailbreak (Sileo, TrollStore auto-install on first boot)   |
| `exp`        | 141 patches | 18 phases | JB superset + anti-VM-detection research patches                  |

See [`research/0_binary_patch_comparison.md`](./research/0_binary_patch_comparison.md) for the per-component breakdown.

The counts above are not annotated with the firmware combination or the date they apply to, and different measurement methods yield different numbers. For example, the Summary table in `research/0_binary_patch_comparison.md` reports boot-chain totals of 46/58/117/132 (regular/dev/jb/exp) and, including CFW, grand totals of 56/70/132/163 — a different method from the per-variant counts in this table; the two sets are not the same measurement and are not interchangeable. Treat dated evidence as authoritative: see [`research/0_binary_patch_comparison.md`](./research/0_binary_patch_comparison.md) and [`research/firmware_compatibility.md`](./research/firmware_compatibility.md).

## Running & Connecting

- **SSH (jailbreak):** `ssh -p 22222 mobile@<vm-ip>` (password `alpine`)
- **SSH (regular/dev):** `ssh -p 22222 root@<vm-ip>`
- **VNC:** `vnc://<vm-ip>:5901`

## Locations

Everything vphone-cli creates lives under `~/.vphone/` — kept outside the repo and the `.app` so the signed bundle stays portable. Redirect the whole tree with `$VPHONE_ROOT`:

| Path              | Contents                                                                                     |
| ----------------- | -------------------------------------------------------------------------------------------- |
| `~/.vphone/`      | The per-user data root — override the entire location with `$VPHONE_ROOT`.                   |
| `~/.vphone/VMs/`  | VM bundles — one directory per VM. This is the library; override with `$VPHONE_LIBRARY_ROOT`. |
| `~/.vphone/ipsws/`| Downloaded iPhone + cloudOS IPSWs, cached and reused across VMs.                              |
| `~/.vphone/tools/`| Cached APFS seal-volume artifacts (`apfs_sealvolume_<version>`) fetched during `fw prepare`.  |
| `~/.vphone/debs/` | Cached `.deb` packages the `jb`/`exp` CFW install lays into the guest (Sileo, apt, …).        |
| `~/.vphone/venv/` | Auto-provisioned Python environment (override with `$VPHONE_VENV_DIR`). |

Precedence: the per-item overrides (`$VPHONE_LIBRARY_ROOT`, `$VPHONE_VENV_DIR`) win over `$VPHONE_ROOT`, which wins over the `~/.vphone` default. The `ipsws/`, `tools/`, and `debs/` caches always sit directly under whichever root is active.

## SIP/AMFI Relaxation

**Option A — fully disable SIP, then disable AMFI via boot-arg (most permissive).**

In Recovery (long-press power → Terminal):

```bash
csrutil disable
csrutil allow-research-guests enable
```

Then reboot into macOS and set the AMFI boot-arg (needs SIP fully off to take effect):

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"   # reboot after
```

**Option B — keep SIP on (debug-only relaxed), then allowlist the binary with amfidont** (leaves AMFI enabled system-wide).

In Recovery:

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

Then reboot into macOS and:

```bash
vphone-amfidont         # .build/vphone-cli.app/Contents/Resources/vphone-amfidont for local builds
```

## Tested Environments

| Host            | iPhone                | CloudOS         |
| --------------- | --------------------- | --------------- |
| Mac16,11 27.0b2 | `17,3_18.6.2_22G100`  | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0_23A341`    | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0.1_23A355`  | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.1_23B85`     | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.3-23D128`   |
| Mac16,12 26.3   | `17,3_26.3.1_23D8133` | `26.3-23D128`   |
| Mac16,11 26.2   | `17,3_26.4_23E246`    | `26.4-23E5207q` |
| Mac16,11 26.2   | `17,3_26.5_23F77`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.5.2_23F84`   | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_26.6_23G71`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.6.1_23G83`   | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A5408d`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5418b`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5424a`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5430a`  | `26.4-23E5207q` |

## Support Scope

The following is the measured scope as of each evidence date, not a general support guarantee for every version combination. All entries use device `iPhone17,3`.

**Firmware compatibility registry (as of 2026-09-09, source `research/firmware_compatibility.json`)**
The registry records 23 catalog version pairings (with exact build numbers, 18.6.2 through 27.0 beta) and 4 cloudOS images (26.1 = `23B85`, 26.2 = build number not recorded, 26.3 = `23D128`, 26.4 = `23E5207q`). All five variants (less/regular/dev/jb/exp) are code_selectable on all 23 pairings (they can be selected into the pipeline; no patch or boot verification performed). Patch-byte verification (patch_verified) covers less 1, regular 7, dev 7, jb 10, exp 7 combinations. On-device capability verification (capability_verified): jb 3 combinations (27.0 series `24A5380h`/`24A5390f`/`24A5408d`, of which `24A5408d` uses `--frida`), exp 1 combination (26.6.1/`23G83` rig-baseline). The regular and dev variants have no complete on-device boot evidence yet.

**End-to-end evidence matrix (as of 2026-09-17, source `research/f1_support_matrix_2026-09-17.md`)**
This round verified two combinations step by step (S1 create through S12 EXP-specific):

- P: 26.1/`23B85` + cloudOS 26.1/`23B85`, all five variants.
- N: 26.6.1/`23G82` (non-catalog build, specified by local path) + cloudOS 26.4/`23E5207q`, jb and exp (`--frida`).

Patch-record counts at the create stage: regular 58, dev 70, jb 152, exp 178, less 26 (P set); jb-frida 157, exp-frida 183 (N set). Known limitations L1–L3 and open questions O1–O3 are not counted as passing and are tracked separately (see `research/f1_known_limits_2026-09-17.json`). The L combination (18.6.2/`22G100`) was not included this round; no IPSW was downloaded and all steps are recorded as not run.

The various patch counts (boot chain / totals / historical method counts) differ between measurement methods; see `research/0_binary_patch_comparison.md` and section 5 of `research/firmware_compatibility.md` for the method notes.

## FAQ

**`zsh: killed ./vphone-cli`** — AMFI/debug restrictions aren't bypassed; see [Prerequisites](#prerequisites) (`amfi_get_out_of_my_way=1` or `amfidont`).

**`Virtualization is not available on this hardware`** — your Mac is itself a VM; PV=3 guest boot can't nest. Use a non-nested macOS 15+ host.

**Stuck on "Press home to continue"** — connect via VNC and right-click (two-finger click) to simulate the home button.

**System apps won't install** — during iOS setup, don't pick Japan or the EU as your region (extra regulatory checks the VM can't satisfy); pick e.g. United States.

**App crashes on launch with `EXC_GUARD` / `GUARD_TYPE_MACH_PORT`** — re-patch with `vphone-cli fw patch <name> --variant <v> --force-exc-guard`, then re-restore/install ([#291](https://github.com/Lakr233/vphone-cli/issues/291)). Always on for iOS 18 bases.

**Install a `.ipa`/`.tipa`** — use the running VM's Install menu (drag-drop or file picker).

**`cfw install` hangs re-signing a system binary (e.g. `Campo`), memory climbing unbounded** — known bug in `ldid-procursus` up to `2.1.5-procursus7` (the current Homebrew `stable`): `bytes(uint64_t)` calls `__builtin_clzll(0)` with no zero-guard, which is undefined behavior, and on this build resolves to a `0`-length that underflows an unsigned loop counter — `ldid` spins writing one byte at a time into a growing buffer instead of terminating. Triggered by *any* entitlements plist containing an integer value of exactly `0` (some real Apple system binaries have these). Fixed upstream but not yet in a tagged release; rebuild from source: `brew install --HEAD ldid-procursus && brew link --overwrite ldid-procursus`. Kill the hung `ldid` process first (`sudo kill -9 <pid>`) if you already hit it.

## Automation

`vphone-cli` exposes a host control socket (`<bundle>/vphone.sock`) for programmatic control — screenshots, touch, swipes, hardware keys, clipboard — each action returning an inline screenshot for AI-driven E2E testing. See [vphone-mcp](https://github.com/pluginslab/vphone-mcp) for an MCP server wrapping it.

When a VM is launched with `--headless` (no VM window), the capability snapshot reports `screen_available=false` and the screen-dependent commands — screenshot, touch, and swipe — are unavailable; hardware keys and clipboard remain available.

## Acknowledgements

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)

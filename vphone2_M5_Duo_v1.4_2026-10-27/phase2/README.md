# Phase 2: dual display and single-display fold emulation (research record)

Archived 2026-10-28 from the M5 Pro run. Contents of this folder:

- `geo-probe/`: GeoProbe and GeoBare (one source, `main.m`), `build.sh sim|device [bare]`,
  `run-sim.sh` (iPhone Duo simulator through Device Hub), `run-vm.sh` (duo-m5-dd).
- `pg-probe/pgprobe.m`: ParavirtualizedGraphics probe P0–P3, outside Virtualization.framework.
- `scripts/`: `dd-matrix.sh` (D0–D3 display topology matrix), `screen-probe.sh`
  (boot at a `VPHONE_SCREEN` size, raw syslog/crash capture), `fold-resize.sh`
  (runtime `display` reconfigure attempt).
- `results/`: the JSON each probe wrote, the matrix table and `pgprobe-P0-P3.txt`. Screenshots, boot logs
  and syslog captures stay on the run host under `~/vphone-duo-m5/run/phase2/`.

The scripts hard-code the run host's paths (`/Users/kolar/...`), the test VM
`duo-m5-dd`, its USB UDID and the experimental bundle `.build/pr728-dd`; the code they
drive is on this branch (commits 49116af3 and 3b99165c). Paths below that start with
`~/vphone-duo-m5/` refer to the run host.

## Status (2026-10-28)

| track | state |
|---|---|
| Single-display inner panel (static) | **Calibrated.** Boot with `VPHONE_SCREEN=2007x2853@430`; the app-visible geometry matches Xcode 27.1's unfolded iPhone Duo simulator in portrait and landscape. Open: reserved regions (occlusion 144 vs 134 pt, no fold division), status bar drawn outside its occlusion region (Safari's left toolbar buttons under the time), `UIScreen.main` is the inner display. Short stability only (~57 s, pids unchanged, launchd CPU flat); no phase-1-style T6. |
| Fold switch on one display | **Parked.** Runtime `display` reconfigure is refused because the guest driver never reports mode-list responsiveness; switching panels by reboot is not a fold. |
| Two real displays | **Blocked at the host, research recorded.** PG accepts one device with two ports (P3) and two devices with distinct serials (P2), with fixed modes connected. The VM service refuses both: ports ≥ 2 need `os_variant_has_internal_content`, two devices get the same serial (`0x12345678 + port`). Route A′ (one GPU, two ports) is the better fit for the one-`gfx` guest devicetree; route B′ (two GPUs) stays a fallback. Both need the VM service changed and an unanalysed guest driver path; neither is pursued here. |
| Phase 1 baseline | Unchanged: `duo-m5-728`, snapshot `phase1-baseline`. All phase 2 runs used the clone `duo-m5-dd`. |

---

# Phase 2: dual display on our own (findings 2026-10-28)

Host, macOS 27.0.1 (26A434), M5 Pro. Probes in `~/vphone-duo-m5/src/phase2/` (vzdisplays.swift signed with com.apple.security.virtualization; pgmax.c).

- Public API: `VZMacGraphicsDeviceConfiguration.displays` "Maximum of one display is supported".
- `+[VZMacGraphicsDeviceConfiguration _maximumAllowedDisplayCount]` returns 1 unless
  `os_variant_has_internal_content("com.apple.virtualization")` (0 here); then it returns
  `PGMaxDisplayPortCount()` from ParavirtualizedGraphics, which is `mov w0, #8`.
- Validation: two displays → "greater than the configured display port count"; `_setDisplayPortCount: 2` → "must be between 1 and the maximum supported".
- Replacing `_maximumAllowedDisplayCount` in-process (returns 2) + `_setDisplayPortCount: 2` + two displays → device validate OK.
- Other private knobs: VZMacGraphicsDisplayConfiguration `_setConnectionType:` (default 0), `_setDisplayIdentifier:`, `_setDisplayMode:`; VZMacGraphicsDevice `_validateDisplayForHotPlug:error:`; VZMacGraphicsDisplay `reconfigureWithConfiguration:error:`.

## XPC service re-check (vmservice.dis, 2026-10-28)

Disassembly of the VM XPC service
`com.apple.Virtualization.VirtualMachine.xpc/.../com.apple.Virtualization.VirtualMachine`
(`~/vphone-duo-m5/run/phase2/vmservice.dis`, 1.06M lines). The PG-device build
routine at 0x100148... decodes the config the client sent and applies its own
gate — a separate process the client-side method swizzle cannot reach:

- 0x1001487c0 decodes the serialized key **`display_port_count`** from the config
  dict → so the port count DOES cross the XPC boundary as serialized data (not
  just a client ivar). Requested count stored at `[x21,#0x6c]`.
- 0x1001487e8 `bl _PGMaxDisplayPortCount` (=8); 0x1001487f0 `cmp w22,w0` /
  `b.hi` → reject if requested > 8.
- 0x100148810 `cmp displays_count, port_count` / `b.ls 0x148918` → displays must
  be ≤ ports, else teardown.
- **Decisive gate at 0x100148918:** `_os_variant_has_internal_content("com.apple.virtualization")`
  - internal build (true) → 0x148940, accept, build the PG device with the ports.
  - not internal (false, THIS host) → `cmp port_count,#2; b.lo 0x148940`:
    - port_count < 2 → accept (single port fine).
    - **port_count ≥ 2 → `mov w22,#0` → teardown → 0x148910 `mov w21,#0` (null
      device) → the start fails.** `PGCreateDeviceWithDescriptor` (0x148890) is
      only reached when w22≠0.

So the service re-applies the SAME internal-content gate the client enforces in
`_maximumAllowedDisplayCount`, independently, on `display_port_count ≥ 2`. The
in-process `method_setImplementation` swizzle in `allowDisplayPorts` only
satisfies client-side `validate()`; it has no effect in the XPC service, which
is why 2 ports + 2 displays passed validate but failed at start with
`VZErrorDomain Code=1` (internalError = the null PG device).

### Matrix result (2026-10-28, CONFIRMED) — `phase2/matrix/`

| row | ports/displays | result | where |
|---|---|---|---|
| D0 | 1/1 | **READY 6s, booted** | — |
| D1 | 2/1 | **FAIL Code=1** | after `Configuration validated`, at `Starting...` |
| D2 | 2/2 | FAIL Code=1 | same |
| D3 | 2/2, 2nd quarter-size | FAIL Code=1 | same |
| Ddev | 2 graphics devices | FAIL Code=2 | client `validate()` (not reached start) |

Verdict: the disassembly reading is confirmed, not just a candidate.
- **D1 is decisive**: 2 ports + a single display still fails Code=1 → the blocker
  is `display_port_count ≥ 2`, not the second display object.
- D3 (2nd display at 349×508) fails identically → not a resource/size limit.
- All rows passed client `validate()` (`diag:built` shows ports=2 was set); the
  failure is uniformly at `vm.start()` → the XPC-service internal-content gate.
- Feedback's H1 (port lost in config copy) is falsified by behavior: if the port
  count had not crossed the XPC boundary the service would see 1 and boot like D0;
  it failed, so the count crossed and tripped the gate. (The `vm-copy` readback
  line did not print — `Dynamic` returned nil for `_configuration.graphicsDevices`
  — so H1 is ruled out by behavior, not by direct readback.)
- The expanded error carries no `NSUnderlyingError`: VZ reports the service's null
  PG device as an opaque `Code=1 internalError`, matching the `w21=0` path.
- Ddev confirms the two-device route is rejected even earlier, client-side, Code=2.

Consequence: port_count ≥ 2 is a **host-capability gate**
(`os_variant_has_internal_content("com.apple.virtualization")`, false on this
consumer Mac), enforced in the XPC service. No client-side return-value patch
reaches it, and the two-device route is also closed at client validate. Viable
landing is single-display Duo driven by `display.posture` (already validated in
phase 1); a genuine second framebuffer would need the internal-content variant
state or an entitlement this host does not have.

---

Original falsifiable predictions the matrix (`dd-matrix.sh`) tested — all held:
- D0 (ports=1, displays=1): boots (gate not entered, port<2).
- D1 (ports=2, displays=1): predicted FAIL Code=1 — isolates the port-count gate
  from the second display object. If D1 instead boots, this reading is wrong and
  the blocker is the second display, not the port count.
- D2 (ports=2, displays=2): predicted FAIL Code=1 (matches the earlier observation).
- D3 (ports=2, displays=2, 2nd quarter-size): size control; same gate predicts FAIL
  regardless of size.
- Ddev (two graphics devices): rejected at client validate with Code=2 (observed).

Diagnostics added to the dd bundle (env-gated, experimental):
`VPHONE_DISPLAY_PORTS` / `VPHONE_DISPLAY_COUNT` / `VPHONE_DISPLAY2_SCALE` separate
ports from displays; `VPHONE_DISPLAY_DIAG=1` dumps the built vs. VM-copied
topology (reads `_displayPortCount` back) to check the port survives the config
copy; errors now print domain/code/userInfo and every nested `NSUnderlyingError`.

If the matrix confirms, the port-count ≥ 2 path is a **host-capability gate**
(`os_variant_has_internal_content`), not a client bug: no amount of client-side
return-value patching reaches it. Remaining options are (a) a two-graphics-device
topology if the guest can drive two single-port devices, (b) the internal-content
variant state, or (c) accept single-display Duo and drive the fold via posture only.

Not yet known (next experiments, in order):
1. Does the VM start with 2 ports? → ANSWERED by the matrix above.
2. Does the vphone600 guest kernel/display stack bring up a second framebuffer?
3. Does FBDisplayManager count it as always-connected (built-in), not external? (connectionType)
4. Host window: a second view bound to display 1.
5. V68 `product-id` for CoreMotion pose managers, touch routing per panel, hinge HID (0xFF0C/0x21, 0x22).

## Route B: two single-port graphics devices (2026-10-28)

Client side: `-[VZVirtualMachineConfiguration validateWithError:]` rejects >1
graphics device with a fixed check (no overridable limit method). Wrapped in-process
(`allowMultipleGraphicsDevices`: validate a copy with only device[0], then each
device on its own). The wrapper runs twice — our `validate()` and again inside
`VZVirtualMachine(configuration:)` — and both pass.

Service side (`phase2/matrix-b/virtualization-start.log`): the VM service accepts
two graphics devices and builds device 0's display (`PGDisplay[0](Apple Virtual/0x12345678): Created`),
then device 1 fails:
`ParavirtualizedGraphics: Display serial numbers must be unique across all devices`
→ `VirtualizationCore:DeviceFactory Failed to initialize device` → `Code=1`.

Why the serial collides (vmservice.dis 0x10014d098 and 0x10014dfac):
`-[PGDevice newDisplayWithDescriptor:port:serialNum:]` is called with
`port = [display + 0xc]` and `serialNum = 0x12345678 + port`. The serial is computed
in the service from the port number; the client display config has no serial or port
field (`_graphicsDisplay` holds size, ppi, two ints, optional identifier string, HDR
flag, UUID). Setting distinct `_setDisplayIdentifier:` and/or `_setUUID:`
(`VPHONE_DISPLAY_IDS=ident|uuid|both`, `phase2/matrix-ids-*`) leaves the serial at
0x12345678 every time.

A single-port device always puts its display on port 0, so every device gets the same
serial. Distinct serials need distinct ports, i.e. one device with ≥2 ports — which is
route A's `os_variant_has_internal_content` gate. Both routes end at the same gate.

## Single-display fold emulation (2026-10-28)

Duo panels (apple.com/iphone-duo/specs): outer 1398x2034 @ 460 (what the VM
uses), inner 1878x2670 @ 430.

**Runtime resize: refused by the guest's capability.** New `vphone.sock`
command `{"t":"display","width":..,"height":..,"ppi":..}` calls
`VZGraphicsDisplay.reconfigure(configuration:)`. It fails with
`VZErrorDomain Code=2 "The display does not support reconfiguration at this
time"`; the VM keeps running (`phase2/fold-resize/`). In the VM service the
display is created after registering
`-[PGDisplay setModeListResponsivenessChangeHandler:]` with the block at
0x10014dd18, which sets `byte[0x79] = (state == 2)`; `supports_reconfiguration`
(0x10014a5ec) is `byte[0x79] || byte[0xb1]` and feeds `can_reconfigure_display`.
So reconfiguration needs the guest display driver to report that it responds to
mode-list changes; this iOS guest never does. Making it would mean changing the
guest's paravirtual display driver and having iOS accept a main-screen mode change.
This is a separate capability from booting with fixed-size displays: PG connects
a display when its first `modeList` is set, so two displays of fixed sizes do not
depend on runtime reconfiguration. Runtime resize is parked, not a precondition.

**Boot-time size: accepted, layout half-adapted.** `VPHONE_SCREEN=1878x2670@430`
(`phase2/inner-boot.sh`, `phase2/screen-inner/`): vphoned 12 s, guest reports
626x890 pt @3x, SpringBoard/backboardd pids stable over 60 s. But the UI still
carries outer-panel metrics: Home uses a 4-column grid with wide side margins and
a bottom dock clipped at the bottom edge (the outer layout has a side dock);
Safari's status bar overlaps its toolbar and the tab bar runs past the right edge.
Likely cause, not yet checked: device identity (devicetree `artwork-device-subtype
= 2034`, MobileGestalt screen metrics, safe-area/corner data) still describes the
outer panel. Real Duo switches panels by display identity, so even with matching
metrics this is "a phone with the inner panel's size", not the Duo's unfolded mode.

## Standalone PG probe and guest pre-check (2026-10-28)

`pg-probe/pgprobe.m`: ParavirtualizedGraphics in our own process, no
Virtualization.framework, no guest. Raw output and host details:
`results/pgprobe-P0-P3.txt`. On this host (macOS 27.0.1, 26A434) device creation
needs `PGCreateDeviceWithDescriptor` (`PGNewDeviceWithDescriptor` is unavailable
in the macOS 27.0 SDK, 26A425) and a private `PGMemoryMapDescriptor` of guest-physical ranges;
without it PG logs "A memory map is required". That SDK marks the callback
memory path (`createTask`, `mapMemory`, …) obsoleted in macOS 27.0. When the
memory-map requirement started is not established here: QEMU's port ties
`PGMemoryMapDescriptor` to the IOSurface-mapper / process-isolation path of
macOS 15.4, and the descriptor has `usingIOSurfaceMapper` and
`enableProcessIsolation` properties, so treat it as a per-version, per-path
choice, not a macOS 27 switch. A host allocation stands in for guest RAM.

| test | result |
|---|---|
| P0 1 device, 1 display | created |
| P1 2 devices, port 0 each, same serial | 2nd display nil, "Display serial numbers must be unique across all devices" (same as the VM service) |
| P2 2 devices, port 0 each, serials S / S+1 | both created |
| P3 1 device, displayPortCount 2, ports 0 / 1 | both created |

Each created display was given a non-empty `modeList` (1398x2034 @ 60 Hz, which
is what makes PG hot-plug it) and every device and display was held for 2 s
before exit. So P2/P3 passed creation and the fixed-mode connect request. PG
itself has no internal-content gate on ports and accepts two devices with
distinct serials; both limits seen earlier are the VM service's own choices.
No guest: nothing here shows memory access, interrupts, a guest driver or frames.
`PGDeviceDescriptor` also has private `displayPortConnectionTypes` and
`externalDisplayPortMask` (built-in vs external per port).

Guest side (read-only). What the VM actually boots is the cloudOS 23E5207q
kernel, not the iPhone Duo IPSW's own: `kernelcache.research.vphone600` in the
machine's restore folder, Darwin 25.4.0 (`xnu-12377.100.591.502.1~2/RELEASE_ARM64_VRESEARCH1`),
IM4P file sha256 `697b013c6c53006c78555bfcb961e44da8e2047a303e0b8da609fea263c0cde6`,
with this machine's JB patches applied. Its devicetree,
`DeviceTree.vphone600ap(.guest).im4p`, has exactly one `gfx` node
(`paravirtualizedgraphics,gpu`, role `APV_GFX`, reg, interrupts). A second
graphics device (route B) would need a second node with its own MMIO and
interrupt, and how VZ would describe it is unknown. One device with two ports
(route A) likely needs no second `gfx` node; whether per-port resources fit the
existing MMIO window was not checked. The guest driver is the fileset entry
`com.apple.driver.AppleParavirtGPUIOGPUFamily` (source tree
`ParavirtualizedGraphics/AppleParavirtKext-IOGPUFamily`); its `AppleParavirtDisplay`
is an IOMobileFramebuffer. Being an IOMobileFramebuffer does not show how many
instances the driver creates. Whether it discovers ports, creates one display per
port and routes modes and completions by port was not determined; that driver
analysis was not continued in this work.

## Inner-panel render size: 1878x2670 vs 2007x2853 (2026-10-28)

App Store Connect screenshot specifications list iPhone Duo outer 1398x2034 (same
as the panel) and **inner 2007x2853**, larger than the inner panel's 1878x2670
(apple.com/iphone-duo/specs does not mention 2007x2853). `phase2/screen-probe.sh`
(replaces inner-boot.sh; keeps raw vphoned replies and reports request failed /
field missing / ok separately; `logs.syslog` takes `seconds` ≤ 60 and
`max_lines` ≤ 5000 and returns `.result.entries`).

| run | display | guest screen | SpringBoard window | Home | Safari |
|---|---|---|---|---|---|
| E0 `1878x2670@430` | 1878x2670 | 626x890 pt @3 | **669x951** | dock clipped at bottom | tab bar past right edge; status bar over toolbar |
| E1 `2007x2853@430` | 2007x2853 | 669x951 pt @3 | 669x951 | dock and search button fully on screen | tab bar and page fit; **status bar still over toolbar** |

SpringBoard lays the inner screen out at 669x951 pt (= 2007x2853 / 3) whatever
the framebuffer is, so E0's clipping was the 43 x 61 pt difference. Both runs:
vphoned 7–9 s; SpringBoard/backboardd pids unchanged over ~57 s; launchd cpu
9.7→10.0 s (E0) and 11.3→11.7 s (E1) over that window; the only new crash report
is SiriSearchFeedback, which also appears on outer-size boots. Syslog windows hit
the 5000-line cap (`truncated: true`), so they are samples.

Open: the status bar overlapping Safari's top toolbar in both sizes. Next: dump
window-scene geometry, safe area and size classes from the Probe app on the VM
and on the iPhone Duo simulator (iOS 27.1 runtime is installed) and compare.
Earlier note "SpringBoard's Duo layout needs two displays" was too strong: it
picks the inner 669x951 layout on a single display.

## App-visible geometry: GeoProbe (2026-10-28)

`~/vphone-duo-m5/src/geo-probe/` (main.m, build.sh sim|device, run-sim.sh,
run-vm.sh): one UIScene app with a system navigation bar and a view pinned to
the safe area; writes Documents/geometry.json. Results under
`run/phase2/geo-{sim,vm-outer,vm-inner}/`.

| | sim outer (default) | VM outer (config) | VM inner `2007x2853@430` |
|---|---|---|---|
| scene screen pt | 466x678 | 466x678 | 669x951 |
| nativeBounds px | 1398x2034 | 1398x2034 | 2007x2853 |
| scale / nativeScale | 3 / 3 | 3 / 3 | 3 / 3 |
| safe area t/l/b/r | 0/0/34/84 | 0/0/34/84 | 82/0/34/0 |
| statusBarFrame | h 2 | h 2 | h 2 |
| nav bar in window | y 24 h 58 | y 24 h 58 | y 24 h 58 |
| size classes h/v | compact/regular | compact/regular | regular/regular |

VM outer matches the simulator's outer display field for field. The iPhone Duo
simulator itself has two built-in framebuffers (`simctl io enumerate`, display
class 0): 2007x2853 and 1398x2034, confirming 2007x2853 as the inner render
size. VM inner reports regular/regular, which Apple documents for the inner
display. Its top safe inset (82) moved from the right edge (84 on outer) to the
top, with the status bar drawn in the top band over y 24–82 where top bars sit.

No inner-display reference yet: this Xcode has no Simulator.app (cannot unfold
from the UI), and `simctl spawn` of an ad hoc tool carrying
com.apple.springboard.testautomation is refused ("Security policy issue"), so
the posture override cannot be sent inside the simulator. Not bypassed.

### Inner-display reference from the simulator (2026-10-28)

Xcode 27.1 has no Simulator.app: simulators are shown by Device Hub
(`com.apple.dt.Devices`), which offers the Duo fold states. With the GeoProbe
Duo simulator unfolded (Book), GeoProbe runs on the inner display in landscape.

| | sim inner, landscape (o 4) | VM inner `2007x2853@430`, landscape-left (o 4) |
|---|---|---|
| window pt | 951x669 | 951x669 |
| sceneScreen nativeBounds | 2007x2853 | 2007x2853 |
| window safe area t/l/b/r | 0/0/34/84 | 0/0/34/84 |
| view safe area t/l/b/r | 82/0/34/84 | 82/0/34/**88** |
| statusBarFrame / nav bar | h 2 / y 24 h 58 | h 2 / y 24 h 58 |
| size classes | regular/regular | regular/regular |
| `UIScreen.main` | **466x678 (outer)** | 669x951 (the only display) |

Same in landscape-right (o 3). Two differences:
- The view-level right safe inset is 88 on the VM against 84 on the simulator
  (window-level 84 on both); cause not known.
- On the simulator `UIScreen.main` stays the outer display while the app is on
  the inner one; on the single-display VM it is the inner one. Code that sizes
  itself from `UIScreen.main` behaves differently on the VM.
Still to compare: inner in portrait (where the VM shows the status bar over
Safari's top toolbar).

### Inner portrait and the status bar (2026-10-28)

Simulator inner portrait (o 2) and VM inner portrait (o 1) report identical
geometry: window 669x951, window and view safe area 82/0/34/0, statusBarFrame h 2,
nav bar y 24 h 58, regular/regular. Only `UIScreen.main` differs (sim 466x678 outer,
VM 669x951).

The status bar itself does not match (`geo-sim-inner-portrait/safari.png` against
`screen-E1/safari.png`):
- simulator: time and Wi-Fi ring grouped at the top right, inside the toolbar
  row; Safari leaves that corner free (buttons and address field shifted left,
  no overlap).
- VM: time at the top left and battery at the top right, the split layout of a
  centred camera cut-out; Safari lays its toolbar across the full width, so both
  ends sit under the status bar.
Window safe areas are equal, so the space Safari reserves comes from something
else: likely the status bar layout and the region it reserves, chosen from the
inner panel's sensor/cut-out data, which the VM does not carry for a 2007x2853
display (the outer layout, right-hand sidebar, matches). Inference, not traced.

### Reserved regions: first layer that differs (2026-10-28)

GeoProbe now builds two apps from one source (`build.sh sim|device [bare]`):
GeoProbe (mode B, navigation bar with left/right buttons and a toolbar) and
GeoBare (mode A, no container, non-interactive overlay of safe area, status bar
rect and reserved regions). Both record `-[UIView reservedRegionsOfKind:options:]`
(iOS 27.1, occlusion and division, inactive included), the status bar rect in the
root view's space, layout guide/margins, additional safe area, content size,
system build and SDK. Runs: `geo-sim-inner-portrait-v2/`, `geo-vm-inner-portrait-v2/`
(sim runtime 24A94401, VM 24A94425, both apps built with the iOS 27.1 SDK, unfolded
inner portrait).

Identical on both, in both modes: window, window and root safe area, safe layout
frame, layout margins, status bar rect (h 2, not hidden), navigation bar and
toolbar frames, traits.

Different:

| reserved region | simulator | VM |
|---|---|---|
| occlusion, active | x 535 y 0, 134x82 (top right) | x 525 y 0, **144x82** |
| occlusion, inactive | x 611 y 677.3, 37x58 | absent |
| division, inactive | x 0 y 455.5, 669x40, margins 20/20 (across the middle: the fold) | absent |

On the simulator the status bar (time + Wi-Fi ring) is drawn inside the active
occlusion region. On the VM the region is there but the status bar is drawn in
the split layout outside it (time top left, battery just left of the region).
Safari keeps its right-hand buttons out of the region on both, so on the VM its
left buttons end up under the time. The missing division region fits the
earlier finding that the VM has no hinge (no V68 product-id for CoreMotion, one
display). Where the occlusion width and the status bar layout come from is not
traced yet.

### Status bar overlap: localisation from the existing data (2026-10-28)

From `results/geo-{sim,vm}-inner-portrait-v2/` and their screenshots (run host,
`GeoProbe/screen.png`), unfolded inner portrait, no new runs:

- **Not Safari-specific.** GeoProbe's standard navigation bar collides on the VM
  too: the clock is drawn over `LeftEdge`, the battery over `RightEdge`. On the
  simulator both buttons are clear and the status bar sits inside the active
  occlusion region.
- **Region reported and honoured on both.** The navigation bar ends its trailing
  button at the occlusion region's left edge on both (≈525 pt VM, ≈535 pt sim,
  from the screenshots, approximate). Navigation bar frame (y 24, h 58), root safe
  area, status bar frame (h 2) and traits are identical. So the first layer that
  differs for the overlap is **where the status bar draws its content**: on the VM
  it uses the split layout (left and right ends of the top band), on the simulator
  a cluster inside the occlusion region. Region data and the app container are
  not the cause.
- **144 vs 134 pt** only moves the trailing bar button by 10 pt; it is not what
  overlaps. Both regions are reported from the root view with
  `IncludeInactive`, margins 0, y 0, h 82, ending at x 669.
- **Division:** the query includes inactive regions. The unfolded simulator
  returns an inactive division (y 455.5, 669x40, margins 20/20) and an inactive
  37x58 occlusion; the VM returns neither, so the VM has no description of them,
  not just no active one. Kept as a limit of the single-display VM.
- **4 pt landscape difference:** measured with the earlier GeoProbe (navigation
  container, no region query): window right inset 84 on both, content view 88
  (VM) against 84 (sim). Which layer adds it is not localised; it needs GeoBare
  in landscape on both.
- **Comparability:** same iOS 27.1 SDK build, content size L, left-to-right, no
  camera or Live Activity. Status items differ: VM 12-hour clock and battery,
  simulator 24-hour clock and Wi-Fi ring. The overlap is about placement, not
  item width.

Testable next hypothesis (read-only, in our own app): the status bar view inside
GeoProbe's own window hierarchy, and the layout class it uses, differ between
the simulator and the VM. Recording that class name and frame in both answers
whether the VM picks another status bar layout for this display.

### Status bar view and the 4 pt landscape inset (2026-10-28)

GeoProbe now also walks every window of its scene for views whose class name
contains `StatusBar` (`statusBarViews`). Simulator and VM, both modes: **none**.
The status bar is drawn outside the app process (SpringBoard), on both, so its
layout class cannot be read from the app. SpringBoard's own log around the
launch (process filter, not truncated: VM 1386 lines / 20 s via `SBLOG=1
run-vm.sh`, simulator 2805 lines via `simctl spawn log show`) shows the
`SB-systemAperture` and `SB-systemApertureCurtain` scenes on both and no line
naming a status bar layout or aperture geometry. The layout choice is not
visible from the app or the log.

Landscape, same interface orientation (3) on both (`*-inner-land-v3`):

| | GeoBare root view | GeoProbe content view (in UINavigationController) |
|---|---|---|
| simulator right inset | 84 | 84 |
| VM right inset | 84 | **88** |

Window inset is 84 on both and `additionalSafeAreaInsets` is 0 on both, so the
4 pt is added by the navigation container on the VM only, not by the window or
the system's safe area. Active occlusion region in landscape: 84x120 at x 867
(simulator) against **84x124** (VM), also 4 pt; the container probably derives
its trailing inset from that region, a correlation not verified. The VM again
reports no inactive division or inactive occlusion.

Summary of the open inner-panel differences, all downstream of SpringBoard's
description of the inner panel's occluded area: the occlusion region's size
(portrait 144 vs 134 wide, landscape 124 vs 120 tall), the status bar drawing
outside it in portrait, and the missing fold regions. Next read-only step: the
data SpringBoard derives the inner panel's sensor/occlusion area from
(MobileGestalt display and sensor keys, devicetree `display0`/`display1`), on
the simulator runtime against the VM.

### Data source of the inner panel's occluded area (2026-10-28)

GeoBare now also reads MobileGestalt (`MGCopyAnswer`) for display, sensor and
product keys, and the zero-argument private `UIScreen` getters whose names
suggest sensor or corner geometry (`sceneScreenPrivate`, `mainScreenPrivate`),
in its own process only (`results/geo-*-datasrc*/`).

- MobileGestalt matches on both (ProductType iPhone19,4, ArtworkDeviceSubType
  2034, DeviceCornerRadius 59, DeviceSupportsDynamicIsland, main screen
  1398x2034 @ 460); no inner-panel key is involved.
- Private screen getters: on the simulator the inner screen and the main
  (outer) screen return the same values, corner radius 59 and `_exclusionArea`
  `{399, 30, 37, 37}`, so these getters are device-level, not per panel. On the
  VM: corner radius 55 and `_exclusionArea` `{250.3, 14, 125.3, 36.7}`, a centred
  Dynamic Island pill.
- The simulator's Duo capabilities.plist lists two integrated displays with
  per-display corner radii and framebuffer masks; the masks are rounded
  rectangles only, no sensor cut-out.

Devicetrees, read with a small property scanner (LZFSE payload decompressed
with libcompression; tools under the run host's scratch directory):

| | v68ap (iPhone Duo hardware) | vphone600ap.guest (the VM) |
|---|---|---|
| `/product` island-notch-location, artwork-device-subtype, display-corner-radius | 144, 2034, 59 | 144, 2034, 59 (same) |
| per-display nodes | `display0` and `display1` | **none** |

v68's per-display properties, floats decoded:

| node | special regions | frame (panel px) | corner radii |
|---|---|---|---|
| `display0` outer, surface-type 1, framebuffer 1C896A2B… | 0: `Jindo`, circular | {1199, 88, 111, 111} = {399.7, 29.3, 37, 37} pt | 5, 5, 59, 59 |
| `display1` inner, surface-type 2, display-index 1, rotation 270, framebuffer BF0DC480… | 0: `BlankableRR`, circular; 1: `Fold` | {63, 710, 111, 111}; {0, 1335, 1878, 0} | 55 x4 |

The outer `Jindo` region in points is exactly the simulator's `_exclusionArea`.
The inner `Fold` region is the division the simulator returns and the VM does
not; the inner region frames are in the physical panel's 1878x2670, not the
2007x2853 render size. Without per-display nodes the VM falls back to the
device-level description: `island-notch-location` 144 (the VM's occlusion region
is 144 pt wide in portrait) and a generic centred island pill, around which the
status bar uses its split layout.

**Finding:** the inner-panel status bar, occlusion size and fold regions come
from the devicetree's per-display `special-region-*` properties, which the VM's
guest devicetree does not carry. Testable fix hypothesis (one change, not
applied): give the VM's display a node with v68 `display1`'s inner-panel
properties (corner radii, rotation, surface type, `special-region-0` camera
hole, `special-region-1` fold) for inner-size boots, then rerun GeoBare/GeoProbe
against the simulator. Open questions before that: the node path and which
process reads it, how the panel-pixel frames map to a 2007x2853 framebuffer, and
how an inner-only devicetree coexists with outer-size boots of the same VM. It
would be a devicetree patch, so it goes through a patch set and preset
(Skills/authoring-patch-sets) and Research/0_binary_patch_comparison.md.

### Inner-panel display node: preparation (2026-10-28, not implemented)

Answers to the three open questions, read-only:

1. **Path.** v68's nodes are `/device-tree/product/display0` (20 props) and
   `/device-tree/product/display1` (22 props), siblings of `camera`, `iopm`,
   `audio`. Property list per node (raw bytes dumped on the run host):
   display-index, display-rotation, display-scale, display-corner-radius (4
   floats), surface-type, has-prox, chrome-identifier, framebuffer-identifier,
   special-regions-count, special-region-N-{type,frame,corner-curve},
   {front,rear}-cam-offset-from-center, side/volume/camera button locations.
   Which process reads them was not traced.
2. **Coordinates.** Region frames mix units: inner `Fold` {0, 1335, 1878, 0} is
   panel pixels (1878x2670, fold at half height = 475.5 pt in the 669x951 layout),
   the camera hole is 111x111 (= 37 pt at 3x). On the VM the panel is 2007x2853,
   so a verbatim copy and one scaled by 2007/1878 (≈1.0687, same on both axes)
   are the two variants to test against the simulator's occlusion {535,0,134,82}
   and division {0,455.5,669,40}.
3. **Delivery.** No restore needed: `cfw install` / `cfw update-environment`
   rewrite the personalized Preboot `devicetree.img4` from its `.bak` (the image4
   bypass accepts a changed IM4P under the original IM4M), and
   `CustomFirmwarePostRestoreDeviceTree` already handles size-changing rewrites
   from the board tree (`withPhoneProduct`, `withBoardAudio`). Existing hooks:
   `VPhoneCustomFirmwareInstaller.swift` ~3227–3243 (`patch-dt-iphone-product`,
   `patch-dt-foldable-vm-subtype`), declarations in
   `FirmwareGuestSystemPatchSet.swift` (target `.prebootDeviceTree`).
   `presentPhoneProduct` copies `/product` properties only, never its children.

Plan: a new `preboot-exp-devicetree_inner_panel_display` (off in `standard`)
that adds a `/product/display0` built from v68's `display1` with display-index 0
for the VM's single display, applied on `duo-m5-dd` only through
`cfw update-environment`, then GeoBare/GeoProbe against the simulator. Open: the
Preboot tree serves every boot of the VM, so an inner-panel node also applies
to outer-size boots until reverted; per-size switching is not designed yet.
Remember Research/0_binary_patch_comparison.md when it lands.

### First run of the inner-panel display node (2026-10-28)

`preboot-exp-devicetree_inner_panel_display` applied to `duo-m5-dd` only (snapshot
`pre-inner-panel-display` before it; `fw set-patches --allow`, then root
`cfw update-environment`; receipt records it in Guest). Boot at
`VPHONE_SCREEN=2007x2853@430`, `results/geo-vm-inner-portrait-dt/`.

Reserved regions now carry the inner panel (landscape, VM o 4 vs simulator o 3,
so the camera region is mirrored):

| region | simulator | VM before | VM with the node |
|---|---|---|---|
| division, inactive | {455.5, 0, 40, 669} | absent | {455.5, 0, 40, 669} |
| occlusion, inactive (camera) | 58x37 at {215.7, 611} | absent | 58x37 at {677.3, 21} |
| occlusion, active (status bar) | 84x120 at {867, 0} | portrait 144x82 | 84x124 at {867, 0} |

`_displayCornerRadius` 55; `_exclusionArea` is still the device-level pill.

New: the node's `display-rotation` 270 makes the system treat the framebuffer as
a panel mounted at 270°, as the real inner panel is. The UI now starts in
landscape (o 4, 951x669), like the simulator's unfolded default, and is drawn
rotated into the 2007x2853 portrait framebuffer, so the host window shows it
sideways (`GeoProbe/screen.png` on the run host). The devicetree values are
right; what is left is presentation. Options: (1) rotate the host view and its
touch mapping by 90° for this display (keeps hardware semantics); (2) a node
variant with `display-rotation` 0 and the region frames rewritten into
portrait coordinates, calibrated against the simulator's portrait values
(diverges from hardware); (3) revert (snapshot, or block the patch and rerun
`update-environment`).

### Host rotation for the turned inner panel (2026-10-28)

`VPHONE_PANEL_ROTATION=<degrees clockwise>` (window controller,
`panelMountDegrees`) adds the panel's mounting to the window's turn only; the
menu's rotation still works from SpringBoard's own orientation, which stays 0°
with the inner-panel node. Touch keeps working through the turned view
(AppKit's conversion undoes the rotation). With the node,
`VPHONE_PANEL_ROTATION=90` shows the interface upright: the window becomes
landscape, the fold division is a vertical band in the middle and the active
occlusion region is the 84 pt column at the top right, as on the unfolded
simulator. Touch mapping in the turned window still to be checked by hand.

Still different: the status bar keeps its split layout (time left of the fold,
battery at the top right over the trailing bar button), while the simulator
stacks time and Wi-Fi in the 84 pt right-hand column. The device-level
`_exclusionArea` is still the centred island pill. On the simulator it is the
outer panel's `Jindo` region (`display0`); the VM's only `display0` now carries
the inner panel's `BlankableRR` hole, so the system appears to fall back to
`/product` `island-notch-location` 144 with `DeviceSupportsDynamicIsland`.
Next hypothesis, one change: drop the device-level island for inner-size boots
(for example `/product/island-notch-location`) and check `_exclusionArea` and
the status bar again. Not applied.

### Touch with the inner-panel node: not delivered (2026-10-28)

With the node and the host turn, touch does not reach apps. GeoBare now logs
every touch it receives (`touchesBegan`, Documents/touches.log);
`scripts/touch-map.sh` sends four frame-buffer points through the host view
(`vphone.sock` `tap`) and four through vphoned (`input.tap`). GeoBare was
frontmost and received none of the eight. Home-screen taps at frame-buffer
positions did not open the icons under them either.

backboardd's log during taps (process filter, 109 lines, not truncated): the
digitizer contacts arrive (`contact 0 presence: touching` / `none`), the hit test
uses `BKSHitTestRegion {{0, 0}, {669, 951}}` (portrait) and the touch goes to an
`(external)` destination, while the interface is laid out landscape (951x669)
under `display-rotation` 270. The node turns the display; the VM's USB touch
screen is not turned with it, so touches are hit-tested in the unturned space
and miss the app's context.

The frame buffer also shows the status bar drawn unturned (portrait, time and
battery along the frame buffer's top) while the rest of the interface is turned,
which is why its split layout lands beside the fold in the turned window.

Consequence: the node as copied (rotation 270) is not usable for interaction.
Options: a node variant with `display-rotation` 0 and the region frames
rewritten into the unturned portrait space (no host turn needed, touch stays
consistent, but the values no longer match the board); find a property that
turns the touch screen with the panel (not identified); or revert and keep the
static inner panel without the node.

### Correction: touch fails at the E1 size itself, not because of the node (2026-10-28)

`duo-m5-dd` reverted to snapshot `pre-inner-panel-display` and its selection
reset to plain `standard` (the patch shows "not applied", nothing differs).

| boot | host-view tap (`vphone.sock tap`) | guest tap (`input.tap`) | GeoBare touch log |
|---|---|---|---|
| outer, configured 1398x2034 | Safari opens | Safari opens | touches logged at pixel/3 (clamped at the 466x678 edge) |
| E1 `2007x2853@430`, no node | nothing opens | nothing opens | no touch logged |
| E1 with the node | nothing opens | nothing opens | no touch logged |

So the earlier conclusion "the node breaks touch" is wrong: touch does not reach
apps at the E1 size with or without the node. backboardd's dispatch mode was
`ignoring` with the node and `sending` without it (both on the E1 size, and
`sending` at the outer size), with the hit-test region the full screen in each
case; posture (closed through open) changed nothing at either size. Where the
E1 touches end up is not found yet. Everything earlier recorded for E1 was
geometry and layout only; touch was never exercised there.

Consequence: the static inner-panel VM (E1) is not interactive. T6 at E1 can
still cover boot, idle and automation through vphoned's non-touch methods, but
not touch interaction, until this is found.

### Where E1 touches go (2026-10-28)

backboardd's log around a tap (process filter, not truncated), outer size against
E1 without the node, message templates compared with addresses removed:

- Outer: the tap moves keyboard focus to the tapped scene
  (`keyboardFocus … target: …UIHostedScene…`), i.e. it hit a context.
- E1: no focus change. Instead, on every tap:
  `setDesignatedMainDisplayUUID: (null)` →
  `reevaluateDisplayArrangementForReason(designated main display changed)` →
  a pointer-region rebuild for `<main>` 669x951. Neither line appears at the
  outer size.
- Both sizes: hit-test region = full screen, touch stream to SpringBoard's
  `(external)` destination, digitizer attention events with `displayUUID (null)`.

Reading (from the log text, not traced in code): at the inner size the Duo
logic that designates the touched panel as the main display is active, and the
VM's USB touch screen carries no display identity, so each tap designates no
display and the touch reaches no app. Making it work would mean associating the
touch screen with a display identity this logic accepts, inside backboardd /
SpringBoard's dual-panel handling.

Decision point: by the criterion set for this track (stop if it needs deep
SpringBoard changes), the interactive static inner panel is not worth pursuing
now. The single-display Duo at the outer size, where touch works, stays the
deliverable; the inner-panel findings (2007x2853, reserved regions, the
devicetree node, the host turn) remain recorded for later.

### R0/R1/R2: display association for synthetic touches (2026-10-28)

vphoned gained an experimental single-finger path, `input.touch_native`
(`vp_hid_touch_edge` with no edge, normalized coordinates), and, when
`/private/var/tmp/vphoned.touch-display` exists, attaches BackBoardServices
digitizer info (`BKSHIDEventSetDigitizerInfo`) naming a display: the file's
contents, or `CADisplay.mainDisplay.uniqueId` when empty. The host pushes the
new vphoned on connect (no root step). `scripts/r-experiment.sh`, E1 size, no
node, GeoBare's touch log as the criterion:

| group | flag | touches received |
|---|---|---|
| R0 | absent | 0/4 |
| R1 | present, empty (main display UUID) | 0/4, and no attachment logged |
| R2 | removed | 0/4 |

With an explicit value in the file, `BKSHIDEventSetDigitizerInfo` is found and
called (`BKSHIDEventDigitizerAttributes` is the attribute class); reading the
value back through a `displayUUID` getter returned null, so the getter's name is
not confirmed. With an empty file nothing was attached because the main
display has no UUID: `CADisplay.displays` in the guest (vphoned `script.eval`)
lists `LCD` (displayId 1, main, uniqueId null) and five `Wireless` entries.
The built-in main display's UUID is null by design, so `displayUUID (null)` on
touches and `setDesignatedMainDisplayUUID: (null)` name the built-in display,
not a missing one. The hypothesis that E1 touches fail for want of a display
identity does not hold; why they reach no app at E1 is still open. The flag
file was removed afterwards.

### T6 at the outer size (2026-10-28, duo-m5-dd, branch bundle)

`scripts/t6o-coldboot.sh` (10 headless cold boots, `results/t6-outer/coldboot.txt`):
10/10 — vphoned 7–9 s; at 180 s uptime launchd 10 s CPU and kernel_task 45–47 s
every boot; SpringBoard 37 / backboardd 73 on every boot; unlock ok; a tap on
Safari through vphoned opens it every time; the only new crash report is
SiriSearchFeedback (8 of 10 boots), the known one.

`scripts/t6o-interact.sh` (windowed, `results/t6-outer/interact.txt`): GeoProbe,
Safari open_url, landscape-left and back, keyboard input into the address bar
(`example.org` shown), food_ordering, Safari back with the same pid (423), no
crash reports. The interaction round ran with the bundle that carries the
vphoned experiment (host pushed the new vphoned on connect); the cold boots ran
before it. Still to run: the 2 h idle (`scripts/t6o-idle.sh`), snapshot and
export/import regression, and a boot after a host restart (needs the user).

### Corrections and build attribution (2026-10-28)

- **R1 attached nothing.** With an empty flag file the code looks up the main
  display's uniqueId, gets null, and returns before calling
  `BKSHIDEventSetDigitizerInfo`, so R1 ran exactly like R0. The only call that
  attached a value was the separate check with a placeholder string, which had
  no GeoBare criterion. So the metadata path is verified to be callable, not
  tested as a fix. Since a null UUID is the legitimate identity of the built-in
  display, no non-empty UUID is invented to retry it; the direction is closed.
  The code stays, off without the flag file, and is not an E1 fix.
- **Build attribution of the T6 runs.** `vphone-vm` cdhash d606ad52… is the same
  for both runs (only vphoned changed), but the guest's vphoned differs:
  | run | host bundle | guest vphoned | result |
  |---|---|---|---|
  | 10 cold boots | before the vphoned experiment | previous | 10/10 |
  | interaction round | with the experiment | pushed on connect (new, flag absent) | passed |
  | 2 h idle | with the experiment | new, flag absent | running |
  These are not one build's complete T6. The final candidate is the newer
  bundle; its cold boots are to be rerun with each binary's hash recorded.
- **Wording.** No new blocking regression observed; the known SiriSearchFeedback
  crash appeared on 8 of 10 boots and is listed separately, not "no crashes".
  The PIDs were read once per boot at 180 s uptime (SpringBoard 37, backboardd 73,
  the boot-time values, so no restart up to that point); the rerun records
  start and end PIDs. The idle run is a locked-screen idle (Auto-Lock 120 s),
  not continuous on-screen operation.
- **E1 status.** Render size and base geometry calibrated; status bar and
  reserved regions still differ; touch reaches no app. Not an interactive inner
  panel test environment. Remaining step, one round only: log `UIWindow.sendEvent`
  in GeoBare (record, then call through) for the same taps at the outer size and
  E1, to find whether touches reach the app's window at all. If locating it
  further needs system processes, stop there.

### Touch trace: where E1 touches stop (2026-10-28)

GeoBare now observes three layers: `UIApplication.sendEvent` (a `GeoApplication`
subclass, app-events.log), `UIWindow.sendEvent` (`GeoWindow`, events.log) and
`touchesBegan` (touches.log), each recording then calling through; its sample
adds the window's class, key/hidden/level, root interaction, scene role and the
scene screen's FrontBoard display configuration. `scripts/touch-trace.sh`: four
host-view taps and four vphoned taps, same bundle and GeoBare, flag absent.

| | outer | E1 |
|---|---|---|
| app touch events | 16 | **0** |
| window touch events | 16 | 0 |
| touchesBegan | 8 | 0 |
| scene display | `Main` LCD, 466x678@3x | `Main` LCD, 669x951@3x (2007x2853) |
| scene activationState (all samples) | 0 | 0 |

At E1 touches never enter the app's UIKit dispatch. The scene sits on the same
`Main` LCD display configuration with the right mode, and is foreground-active,
so a scene-on-another-display mismatch (H1) and an inactive scene are not what
the app side shows. The sender-side conversions are right: icli scales points
by `CADisplay.mainDisplay`'s real bounds (669x951 at E1), the host by the 2007
pixel width. What remains is between backboardd's receipt of the contacts and
the app: a system window or input region taking them (H2), a size or transform
inside backboardd (H3 there), or the app's event channel not registered for
routing (deeper H4). Locating it needs observation inside system processes
(SpringBoard / backboardd, through SystemHook), not done.

### Idle, first 60 minutes (2026-10-28, stopped on request)

`results/t6-outer/idle-60min.tsv`, outer size, headless, newer bundle: SpringBoard
37 / backboardd 73 / vphoned 246 unchanged throughout; launchd CPU 9.68 → 14.76 s
over 3601 s (0.14 % average, slowing), kernel_task about 3.5 % of a core steady;
memorystatus level 55 → 48 then flat; screen reported unlocked and on in every
sample; one `ReportSystemMemory` report at the last sample. The run was stopped at
60 of 120 minutes to free the VM; the 2 h idle is still to be done.

### SpringBoard touch diagnostic: the status bar window takes E1 touches (2026-10-28)

`VPhoneGuestComponents/TouchDiag/libtouchdiag.m`, loaded into SpringBoard by
SystemHook and inert unless `/var/mobile/Library/Caches/vphone-touchdiag.flag` exists at
SpringBoard start, wraps `-[SpringBoard sendEvent:]` to log each touch's
window, level, frame and hit view, then calls the original. `scripts/sb-trace.sh`
turns it on, resprings, taps the Home screen 4 times by host view and 4 by
vphoned (Home pressed between), pulls the log, turns it off and resprings.
Installed hash, load and wrap are logged in each run (`results/sb-trace/`).

| hit window (besides `_UISystemGestureWindow`) | outer | E1 |
|---|---|---|
| `SBHomeScreenWindow` level -2 → `SBIconView` / `SBIconListView` | 12 | 0 |
| `SBStatusBarWindow` level 999 → `STUIStatusBarForegroundView` | 0 | **16** |

Both SpringBoards wrap and log, and both receive every tap, so backboardd
delivers to SpringBoard at E1 too and the coordinates are right (E1 points
like 200.7,427.7 sit in a 669x951 window). The difference is hit-testing: at
E1 the status bar window's foreground view claims points in the middle of the
screen, so every touch goes to the status bar and none to the Home screen or
to the app below it. This is H2, now observed rather than inferred. It fits
the split, wrong status bar seen at E1 since the first inner-size run.

### Why the status bar claims E1 touches: provider selection (2026-10-28)

libtouchdiag v6 adds, all read-only: the hit view chain for status bar hits,
the status bar windows and their visual provider at the first touch, the
provider classes in the runtime with their size getters, and each family's
`visualProviderSubclassForScreen:visualProviderInfo:` called with a proxy
that forwards to `UIScreen.mainScreen` and records what it is asked.

- At **both** sizes `SBStatusBarWindow`, `STUIStatusBar_Wrapper`, `STUIStatusBar`
  and `STUIStatusBarForegroundView` are screen-sized with identity transforms
  (466x678 outer, 669x951 E1). Screen-sized bounds are normal; at outer the
  taps still pass through.
- The provider differs: outer `STUIStatusBarVisualProvider_AxisAlignableSplitV68Cover`
  (height 77), E1 the generic `STUIStatusBarVisualProvider_DynamicSplitSmallIsland`
  (height 53.67). StatusBarUI ships inner-panel providers
  `AxisAlignableSplit1878`, `…2007` (width 2007, scale 3), `…2670`, `…2670_VM`,
  `…2853_VM`, all with `notchSize` 37x37, like `V68Cover`.
- `+[AxisAlignableSplit visualProviderSubclassForScreen:]` reads only
  `_nativeDisplayBounds`, `_exclusionArea` and `_nativeScale` (`_scale` too at
  outer). Outer: 1398x2034, exclusion `{399, 30, 37, 37}` (a 37 pt hole), scale
  3 → `V68Cover`. E1: 2007x2853, exclusion `{250.333, 14, 125.333, 36.667}`
  (an island-shaped pill), scale 3 → **nil**, and the Split family falls back
  to `DynamicSplitSmallIsland`.

So the native size matches `AxisAlignableSplit2007`; what fails is the screen's
exclusion area, which at E1 describes a small-island pill instead of the inner
panel's 37x37 camera hole. The wrong provider then both draws the split status
bar and claims the screen's touches. The fix target is the exclusion area the
main display reports at E1 (devicetree special region / display description),
not hit-testing.

### The exclusion area alone decides it (2026-10-28)

libtouchdiag v7 repeats the AxisAlignableSplit selection at E1 with the proxy
answering `_exclusionArea` with a substitute `UISDisplaySingleRectShape`
(`-initWithRect:`), everything else from the real screen:

| `_exclusionArea` given | result |
|---|---|
| real: `{250.333, 14, 125.333, 36.667}` (pill) | nil → `DynamicSplitSmallIsland` |
| `{399, 30, 37, 37}` (outer Jindo, what the simulator reports for both panels) | **`AxisAlignableSplit2007`** |
| `{602, 30, 37, 37}` (same hole, top right of the inner screen) | **`AxisAlignableSplit2007`** |

The selection is a probe call; nothing in SpringBoard changed. The shape class
carries SpringBoard's `+sb_displayShapeForScreenType:` and
`+sb_thisDeviceDisplayShape`, so the screen's shape is chosen from a screen
type, which at the inner render size is evidently not the V68 one. Next: find
where that screen type and shape are decided for the main display, read-only,
then decide the repair point.

### Screen type: 31 at outer, 32 at E1 (2026-10-28)

libtouchdiag v8, pure class methods and lookups in SpringBoard:

| | outer | E1 |
|---|---|---|
| `SBHScreenTypeForCurrentDevice()` | 31 | **32** |
| `+[UISDisplayShape sb_thisDeviceDisplayShape]` | `{399, 30, 37, 37}` | `{250.333, 14, 125.333, 36.667}` |

`+sb_displayShapeForScreenType:` is the same table at both sizes (types 3–32;
0 and 33+ nil): type 31 is the V68 cover's 37 pt hole, type 32 the island pill
E1 reports. The screen type follows the main screen's size: the inner render
size classifies the device as type 32, whose shape is a pill, so the exclusion
area is a pill, AxisAlignableSplit finds no match, DynamicSplitSmallIsland is
chosen and its screen-sized foreground view takes every touch. On the
simulator the screen type is device-level (its inner screen reports the cover's
`{399, 30, 37, 37}`), which is why it picks the inner AxisAlignableSplit there.

### Cutout-only correction: preparation (2026-10-28)

The devicetree is not the source of E1's pill (it stayed with the inner-panel
node on), so the correction is a SpringBoard runtime override, not a devicetree
change. `VPhoneGuestComponents/InnerCutoutFix/libinnercutoutfix.m`, SystemHook,
SpringBoard only, separate from the read-only `libtouchdiag`:

- Gate: `/var/mobile/Library/Caches/vphone-innercutout.flag` present at SpringBoard start with
  a rect `x y width height` in points; otherwise it logs "inactive" and changes
  nothing.
- Match: `-[UIScreen _exclusionArea]` on the main screen, native size exactly
  2007x2853, original answer the type 32 `UISDisplaySingleRectShape`
  `{250.333, 14, 125.333, 36.667}`. Every other call gets the original.
- Applied: a `UISDisplaySingleRectShape` built with `-initWithRect:` from the
  flag's rect. Unchanged: screen type, provider selection, rotation (0),
  hit-testing.
- Log: `/var/mobile/Library/Caches/vphone-innercutout.log` (loaded / enabled /
  applied with calls and matched counts).
- Rect for C1: `{399, 30, 37, 37}`, what the simulator's inner screen reports
  (device-level). The inner camera's own position (v68 `display1` BlankableRR
  `{63, 710, 111, 111}` in 1878x2670 panel pixels, authored for the 270° mount)
  needs a derived conversion and is left for the visual layout work; both
  positions select `AxisAlignableSplit2007` in the probe.
- Rollback: remove the flag and cold boot. The library stays in `/usr/lib`,
  inert. No root step, no restore, no snapshot needed (the disk change is the
  environment library and two flag files in `/var/mobile/Library/Caches`; `/private/var/tmp`
  is cleared at every guest boot, so flags there do not reach a cold boot).

`scripts/cutout-run.sh C0|C1|C2`: boot 1 syncs libraries and sets the flags,
boot 2 is the measured cold boot; records library and bundle hashes, the fix
log, the live status bar provider and bounds, the screen's exclusion area and
the selection result, Home screen taps (hit window and foreground app after
each, host and guest paths) and GeoBare's three event layers.

### Home screen per tap: 0/8, 8/8, 0/8 (2026-10-29)

`scripts/cutout-home.sh`, same build (libtouchdiag `885d001976c3`,
libinnercutoutfix `95c4c58b5225`), cold boot per state. Four icons, centres
measured from the screenshots (page 1 is the same in all states): Notes,
Maps, TV, Settings, each by host view and by vphoned. Before every tap Home is
pressed twice and SpringBoard is verified frontmost; after it a screenshot and
the foreground app are compared with the icon's bundle ID.

| | C0 (off) | C1 (on) | C2 (off) |
|---|---|---|---|
| live provider | DynamicSplitSmallIsland | AxisAlignableSplit2007 | DynamicSplitSmallIsland |
| frontmost before each tap | SpringBoard 8/8 | SpringBoard 8/8 | SpringBoard 8/8 |
| hit (diagnostic) | SBStatusBarWindow / STUIStatusBarForegroundView 8/8 | SBHomeScreenWindow / SBIconView 8/8 | status bar 8/8 |
| intended app opened | **0/8** | **8/8** (both paths) | **0/8** |

Visual (`results/cutout-home/C0|C1/home.png`): C0 shows the split status bar
(time top left, battery top right); C1 stacks time and battery in the top
right corner, as the simulator's unfolded inner screen does. The Home grid is
the same in both; only the status bar changes.

Corrections to the earlier notes: the Home grid does not change with the fix
(it was read wrongly), and the first series' C0 reading of Notes/Maps/Reminders
as frontmost after status-bar-hit taps is not reproduced here, where the
before-state is checked; it is left unexplained and superseded. The
diagnostic's timed icon dump returned views with UUID identifiers that are not
on page 1, so the icon centres are taken from screenshots.

Status: at E1, with the cutout correction on, touches reach the Home screen and
apps on both input paths, and the status bar uses the inner-panel provider;
off before and after, they do not. Static inner-size input repair shown; not
yet covered: landscape, drag and cancel, Safari, foreground/background,
lock/unlock, outer size unaffected, and the cutout's true inner position.

### Outer size with the cutout correction on: unchanged (2026-10-29)

`scripts/cutout-home.sh C0|C1 outer`, same build, cold boots at 1398x2034,
outer grid icons measured from a screenshot (Notes, Maps, TV, Settings), then
GeoBare.

| | outer, fix off | outer, fix on |
|---|---|---|
| fix log | loaded, inactive | enabled (wrapped), **no `applied` line**: never matched |
| live provider | AxisAlignableSplitV68Cover | AxisAlignableSplitV68Cover |
| intended app opened | 7/8 | 7/8, the same taps |
| hits | SBIconView 7, SBIconListView 1 | identical |
| GeoBare app / window / touchesBegan | 16 / 16 / 8 | 16 / 16 / 8 |

The one miss in both is the host tap on TV (x 57 pt, near the left edge): the
saved window frame for duo-m5-dd had shrunk again (170x247), so within the
fixed 32 view point edge threshold the down went to x 0.3 and the up to x 57,
on empty list space. The vphoned tap on the same icon opened TV in both. This
is the host's small-window edge handling, not the correction. With the
correction on, the outer size behaves exactly as with it off.

### E1 regression with the correction on (2026-10-29)

`scripts/e1-regress.sh on|off`, same build, cold boot each, saved window frame
cleared first; vphoned input; GeoBare's window log counts phases.

| check | on | off |
|---|---|---|
| landscape (SpringBoard 90°), 4 taps in GeoBare | began 4 / ended 4, at the sent landscape points | no events |
| drag, 1 swipe in GeoBare | began 1, moved 20, ended 1 | no events |
| Home page swipe | page 2 shown | (not compared) |
| finger down, Home while down, up; then 4 taps | Home went to SpringBoard; 4 / 4, no stuck touch | no events |
| background, relaunch without terminating, 4 taps | 4 / 4 | no events |
| lock (power), unlock, 4 taps | GeoBare frontmost again; 4 / 4 | no events |
| Safari | opens, page loads | opens |

Visual, `results/e1-regress/on/`: in landscape GeoBare reports one active
occlusion region `{867, 0, 84, 124}` and a right safe area of 84, the
simulator's unfolded inner layout (84x120 at {867, 0}); time and battery sit
in that right-hand column. Safari shows its top toolbar with the tab bar, and
the status bar fits at the right of it without overlapping the buttons. The
Home screen, after Home in landscape, is drawn portrait. Not yet checked: a
tap on Safari's address field itself (the scripted tap at the bottom hit
page content, as Safari uses a top toolbar here) and the cancel phase as
GeoBare sees it (only the absence of a stuck touch afterwards).

### E1 gaps closed: Safari by touch, cancellation phases (2026-10-29)

`scripts/e1-gaps.sh`, correction on, cold boot, vphoned input throughout
(no host taps in this run).

Safari, touch-driven, not launched by command:

| step | result |
|---|---|
| Dock icon tap | Safari frontmost |
| portrait, tap the top address field | focused: URL selected, Favorites / Suggestions panel |
| type `neverssl.com` + return | navigates (address and tab title change) |
| tap page content | Safari stays frontmost |
| landscape, tap the address field, type `example.com` + return | focused, navigates, page renders |

No software keyboard is shown when the field is focused; the guest appears
to report a hardware keyboard. Visual: in both orientations the toolbar's
translucent right-hand button group (share, new tab, tabs) is drawn over the
end of the address field's text. Recorded as a layout observation, not
investigated.

Cancellation, GeoBare window log, with no injected cancel:

```
96.408  began      327,475
96.920  moved      341,503
96.920  cancelled  341,503   (Home pressed while the finger was down)
```

The finger's later release reaches nothing in GeoBare; the next two taps
arrive as began/ended pairs at their points. Note: `input.touch` takes
normalized coordinates by default, so the earlier regression's cancel step
(point values) touched outside the screen; only its "no stuck touch
afterwards" result stood, and this run replaces it.

### Packaged as an opt-in guest patch (2026-10-29)

`system-springboard-exp-inner_cutout`, "Duo inner-screen UI compatibility
(experimental)", in the guest system set: `.guestFile`
`/usr/lib/libinnercutoutfix.dylib`, iOS 27.1 only, not applicable to
non-foldable boards, manual-only and blocked in `standard`, `tvos`,
`tvos-4k`, `homepod-mini`. Lifecycle as `libprefsfix`: the selection is the
one source of state; `cfw install` / `cfw update-environment` install the
library while it is selected and remove it when not, and the host's live
environment sync (`selectedLibraries`) only replaces an installed copy. The
library (v2) has no flag file: present is on; the hole is a constant
`{399, 30, 37, 37}`; the match is unchanged; the first unmatched call is logged
"not applied: unsupported configuration". Build passes bundle admission;
`Version requirements`, `Patch selection`, `Patch declarations`,
`Plan resolution`, `Patch gate`, `Bundled patch set catalogue` pass (the
rest of FirmwarePatcherTests fails only on absent reference firmware).

Enabled on duo-m5-dd with `fw set-patches duo-m5-dd --allow
system-springboard-exp-inner_cutout` (selection was bare `standard`) and root
`cfw update-environment duo-m5-dd`. `scripts/patch-verify.sh`, one cold boot
each, saved window frame cleared:

| | E1 | outer |
|---|---|---|
| selection / receipt Guest | on / recorded | on / recorded |
| library bundled = installed | `b49ec215ce2e` = `b49ec215ce2e` | same |
| library log | applied, 200 of 200 calls | loaded; "not applied: unsupported configuration (native {1398, 2034}, cutout {399, 30, 37, 37})" |
| live provider | AxisAlignableSplit2007 | AxisAlignableSplitV68Cover |
| Home icons opened (host + vphoned) | 8/8 | 8/8 |
| GeoBare app / window / touchesBegan | 16 / 16 / 8 | 16 / 16 / 8 |

The touch diagnostic's log accumulates across boots; the script reads its
last provider entry (the first E1 read took an older boot's line and was
corrected in its results). The old `vphone-innercutout.flag` was deleted from
the guest.

### Patch lifecycle on → off → on (2026-10-29)

Each step: `fw set-patches`, root `cfw update-environment duo-m5-dd` by the
owner, one E1 cold boot with `scripts/patch-verify.sh`.

| | on | off | on again |
|---|---|---|---|
| selection / receipt Guest | on / recorded | off / not recorded | on / recorded |
| installed library | `b49ec215ce2e` | **absent** (the host's sync on connect did not reinstall it) | `b49ec215ce2e` |
| live provider | AxisAlignableSplit2007 | DynamicSplitSmallIsland | AxisAlignableSplit2007 |
| Home icons opened | 8/8 | 0/8 | 8/8 |
| GeoBare | 16 / 16 / 8 | 0 / 0 / 0 | 16 / 16 / 8 |

The off run's library log lines are the previous boot's (the library was not
loaded, so it wrote none). The selection is the single source of state; no
leftover marker keeps the correction on or off.

### Host window: the saved frame shrank on every launch (2026-10-29)

`scripts/window-frame-cycles.sh`: from no saved frame, five E1 launch/stop
cycles with no resize, the last two with a landscape and back rotation.

| cycle | before the fix | after |
|---|---|---|
| 1 | 669 x 951 | 692 x 983 |
| 2 | 646 x 918 | 692 x 983 |
| 3 | 623 x 886 | 692 x 983 |
| 4 (+ rotation) | 601 x 854 | 692 x 983 |
| 5 (+ rotation) | 578 x 822 | 692 x 983 |

Cause, from one launch with the frame logged at each step: the window
restored its autosaved frame (`setFrameUsingName`) before the unified toolbar
and the Home accessory were added. The saved frame is written with them, so
applied to the bare title bar the content lost the toolbar's 32 points on
every launch, and the content aspect ratio narrowed the width to match. After
enough launches the window was about 150 x 150, where the fixed 32 view point
edge zone covered a third of the width, so host taps at 0.3 and 0.7 began as
edge touches. Fix: restore and autosave after the toolbar and accessory are
installed (`VPhoneVirtualMachineWindowController`). A rotation round trip
keeps the size; the origin moves by 1 point (centre rounding).

With the saved frame kept (no clearing, `KEEP_FRAME=1 scripts/patch-verify.sh`),
patch on: outer 8/8 icons including the host tap on TV beside the left edge,
GeoBare 16 / 16 / 8; then E1 8/8, 16 / 16 / 8. Switching between the outer and
inner sizes refits the frame once to the other aspect (692 x 983 → 676 x 961);
whether a following E1 launch keeps it is not yet checked.

The edge threshold itself is unchanged: 32 view points is a host-window zone
for starting guest edge swipes, about 31 guest points at this window size.
It misjudged taps only because the window had shrunk.

## T6 at E1 on the frozen candidate (2026-10-29)

Candidate (`results/t6-e1/coldboot.txt` header): source `78b79d0f` (clean),
vphone-cli `35978b7e05ce`, vphone-vm `b0acd6912114`, vphoned bundled = guest
`9bab82f7d642`, libinnercutoutfix bundled = guest `b49ec215ce2e`, SystemHook
`3d4e8300db6c`; selection `standard` + `system-springboard-exp-inner_cutout`,
recorded in the receipt; `VPHONE_SCREEN=2007x2853@430`, rotation 0; touch
diagnostic flag off (libtouchdiag installed, inert).

### Cold boots: 10/10

`scripts/t6e1-coldboot.sh`, headless: vphoned ready 6–9 s; at 180 s launchd
8–9 s and kernel_task 3–4 s CPU; SpringBoard 37 / backboardd 73 / vphoned
115–117 every boot; unlock ok; the cutout patch logged a new `applied` line
every boot; vphoned tap 10/10 opened `com.apple.mobilenotes`; no new crash
reports.

The host tap opened `com.apple.reminders` in all 10, not Maps.
`scripts/t6e1-hostcheck.sh` reproduces it only with the cold-boot order (Notes
by vphoned, one Home, host tap): the screen after that Home is the widgets
page (`results/t6-e1/hostcheck-widgets-page.png`), where the tapped point lies
on the Reminders widget, and the host tap opened what was under it; with the
Home screen's first page showing, the same host tap opens Maps, as does the
vphoned tap. So the host path delivered every touch; the script did not
verify which page was showing. The first C0 series' unexplained
Notes/Maps/Reminders readings fit the same widgets page.

### Interaction round: all pass

`scripts/t6e1-interact.sh`, windowed, saved frame kept (676 x 961, the size
after the outer → inner refit; still 676 x 961 at the end, so the refit was
one-time). GeoBare began/ended 4/4 in portrait, landscape-left (90°) and
landscape-right (270°), after a respring (SpringBoard 37 → 530), after
lock/unlock (locked and screen off confirmed) and after a guest restart.
Home icons Notes and Maps opened by host view and by vphoned (4/4). Safari by
touch: Dock tap, address field, `example.org`; food_ordering
(`com.autophone.foodorderingdemo.v2`) launched and tapped; Safari kept pid 486
across background and foreground. No crash reports in the round.

## D3 G0: the guest display driver is multi-port (2026-10-29, read-only)

Kernel: `kernelcache.research.vphone600` from duo-m5-dd's restore folder (IM4P
sha256 `697b013c…`, the cloudOS 23E5207q kernel the VM boots), payload
extracted with `ipsw img4 im4p extract`; fileset entry
`com.apple.driver.AppleParavirtGPUIOGPUFamily` 15.0.0 extracted with
`ipsw kernel extract` and disassembled (`ipsw macho disass`); classes from
`ipsw kernel cpp`; personalities from `__PRELINK_INFO`. Nothing patched. All
addresses are in that kernelcache.

Facts (from the disassembly):

- `setupMMIO` (`sub_fffffe0007ebe9a8` region): the register block used below is
  MMIO BAR + 0x1000 (`this+0x398`).
- `setupVersion` (`sub_fffffe0007ebea84`): writes protocol version **0xfc (252)**
  to block + 0x34 (MMIO 0x1034), reads the host's answer; 0 / −1 → "host doesn't
  appear to be configured with GPU"; otherwise walks down a version table to a
  common version, which must be > 9 ("Version doesn't support mapper").
- `configureDevice` (`sub_fffffe0007ebf6cc`): port count = block + 0x22c
  (**MMIO 0x122c**), stored at `this+0x2e8`; 0 → 1; ≥ 9 → 8 with "DisplayPortCount
  configuration (%u) exceeds max (%u)"; published as the `DisplayPortCount`
  property. With flag `this+0x559`, block + 0x234 (MMIO 0x1234) is read into
  `this+0x2ec`: 2 bits per port, a per-port connection type.
- Channels (`sub_fffffe0007ebd3b4`): for each port an `AppleParavirtVirtualChannel`
  named `Display[%u]`, channel id port + 4, 0x4000 bytes, stored at
  `this+0x3d8 + 8·port` (8 slots).
- `AppleParavirtGPU::start` (`sub_fffffe0007ebcf00`, loop at `0xfffffe0007ebd060`):
  for port 0 ..< portCount: `AppleParavirtDisplay` allocated through its
  metaclass, `init(gpu, port)` (`sub_fffffe0007eb4024`, fails unless
  port < portCount), stored at `this+0x350 + 8·port`, attached, its
  connection-type bits examined, started.
- The only IOKit personality is `AppleParavirtGPUARM` (IOClass
  `AppleParavirtGPU`, IONameMatch `paravirtualizedgraphics,gpu`); displays are
  created by the GPU, one per port, not by matching. `AppleParavirtDisplay`
  (0x2ae8 bytes) is an IOMobileFramebuffer; strings `PGDisplay[%u]` and the
  assertion `fSharedState->port == fPort` show per-port state.

Inference: the guest driver needs no change to drive two ports on one GPU
(route A′): it creates one framebuffer per port the host reports, up to 8,
each with its own channel, and it proposes protocol 252, above the 245
threshold another PG implementation (reims-vgpu) documents for multi-port
reporting. The register offsets (0x1034 version, 0x122c port count) match that
documentation. Not shown statically: what the host's PG answers to 252, whether
the existing MMIO window covers port 1's registers (same device, so likely),
and how the iOS userland (IOMobileFramebuffer clients, backboardd,
SpringBoard) treats a second built-in framebuffer and assigns inner / cover
roles.

So for D3 the blocker is the host alone: the VM service refuses a port count
of 2 unless `os_variant_has_internal_content` (recorded above). Guest-side
work starts only once a host gives the guest two ports.

### Locked-screen idle, 120 minutes: pass

`scripts/t6e1-idle.sh 120`, headless, frozen candidate, screen locked with the
power button after boot. All 13 samples report `locked true, screen_off true`.
SpringBoard 37 / backboardd 73 / vphoned 117 unchanged throughout; launchd CPU
8.82 → 18.60 s over 7202 s (ΔCPU/Δwall 0.00136, i.e. 0.14 %, falling per
interval); kernel_task about 2.8 % of a core, steady; one `ReportSystemMemory`
report from the 100-minute sample on (a memory report, not a crash). The
script stops the VM at the end, so the post-idle interaction check (unlock,
tap, input after the long idle) was not part of this run.

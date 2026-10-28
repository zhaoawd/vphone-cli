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

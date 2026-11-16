# Native Duo probes

The original geometry, keyboard and CSSC sources are copied unchanged from
the experiment directory, with SHA-256 provenance in `sources.json`.
TapProbe was added on 2026-11-02. These sources contain no firmware,
application build products, or user account state.

```zsh
zsh Research/Integration/duo_m5_20261030/Probes/build.zsh device
zsh Research/Integration/duo_m5_20261030/Probes/build.zsh sim
```

The build script creates a new directory under `.build/validation/probes`, or
an explicit new output directory, and builds/signs the apps without installing
or launching them. It also builds the host CSSC command; running that command
requires a host with CSSC support. The probe's JSON checks instruction results
and reports timings; timings alone do not establish guest compatibility.

- GeoProbe / GeoBare: scene, display, safe-area, and size-class geometry with
  and without a navigation container.
- KBProbe / KBProbeFS: focused-field behavior with `UIRequiresFullScreen`
  false or true.
- Probe: guest CSSC correctness and relative timings.
- TapProbe: nine buttons, actual UIControl counters, PID, effective scene
  geometry, App-owned UIKit window coordinates for each button, and the last
  touch received by its window. Scene geometry changes
  are recorded even when a 180-degree turn keeps the same dimensions.

Build only TapProbe with `build.zsh device <new-directory> tap`. An optional
fourth argument, such as `27.1`, explicitly sets the executable's
`LC_BUILD_VERSION` SDK declaration using `vtool` before signing. The headers
and compiler still come from the local SDK. This tests UIKit's SDK-dependent
compatibility policy; it does not test APIs from an unavailable SDK. On this
Xcode 26.4 host, the default declaration produces a 375×667 compatibility
canvas, while a 27.1 declaration uses Duo's native panel dimensions.

Installation-path acceptance must install device IPAs through `ideviceinstaller` and
installd, then launch through `apps.launch`. Installing through `apps.install`
does not exercise the installd path. Use an isolated acceptance machine and
record the IPA hash and bundle ID alongside results.
The element-tap-only harness uses `apps.install` for its disposable TapProbe;
its verdict covers touch delivery and button actions, not installd.

`remap-probe/build.zsh <new-.build-directory> <built-vphone-cli>` builds the
RemapProbe app, an embedded framework, and external dylib/standalone pairs
signed in ldid (flags 0) and Apple ad-hoc (flags 2) forms. It does not install
or launch them. The app records 20 main/framework remap cases: partial/whole
`__TEXT`, private/shared, anywhere/fixed overwrite, and retained 16-alias
cases. It queries actual current/maximum protections, compares bytes, and
executes each alias; no permission repair is attempted. External library
constructors/exports and `DYLD_INSERT_LIBRARIES` in standalone children are
separate checks. The generated app has no custom-trust entitlement at build
time; `apps.install` adds one, so the runtime harness records that input and
supports a separate `run-no-custom-trust` pass removing only that entitlement.

The App's direct `posix_spawn` returns EPERM for both signature forms on the
tested fresh guest. Its original assertion remains in the App harness.
`Regression/txm-standalone-runtime.mjs <socket> <new-output> <app.json>
<probe-build> exec-env` checks the independent path: temporary launchd jobs
run the generated flags-0 launcher, which sets the controlled injection
environment and execs each separately signed target. Reports must identify
the expected executable and successful constructor/export calls. Every job is
unloaded; plists remain in a cache directory, outside auto-loaded directories.
The initial direct job environment did not retain DYLD_INSERT_LIBRARIES in
the observed service description; its failing results remain separate.

`Regression/txm-remap-runtime.mjs` accepts only `duo-txm-remap-20261116` and
`duo-overall-20261116`, checks
the restored TXM receipt, and records installed signatures and per-case
results. It requires a completed report from the newly launched PID. A
successful remap syscall without actual RX and successful execution fails the
regression. The standalone ad-hoc injection assertion is retained even if it
exposes the upstream compatibility limit. Physical installation, CMS-signed
hot reload and stock-iOS policy equivalence are outside this probe's verdict.

`remap-probe/build-context.zsh` builds the separate
`com.vphone.tests.remap-context` identity with no-sandbox/no-container and a
dedicated cache output path. Pass that identifier as the final runtime argument;
the default sandboxed App and its failing spawn assertion are preserved.
The context probe passes both standalone signatures after removing custom-trust.
This is an explicit test entitlement context, not a change to ordinary Apps.

`remap-probe/build-mutation.zsh` builds a standalone probe with an isolated code
page. `Regression/debug-mutation-runtime.mjs <new-output> <build> inline`
checks a 42→91→42 in-place branch hook and real LLDB attach/read/write/detach,
including resumed-process confirmation of 41→73→41. It uses temporary launchd
jobs and unloads every job. The context App must already be installed; the
script launches it when needed and terminates a process it started.
The separate `alias-first`, `source-first` and `debug-alias` modes retain the
dirty-code mapping failures; their assertions are not replaced by the inline
mode's verdict. A `dynamic` build policy adds only dynamic-codesigning for the
recorded controlled comparison; that comparison still fails alias RX.

`Regression/pairing-protocol-runtime.mjs` checks the existing CoreDevice pairing
using three guest-origin Darwin notifications and actual device requests.
It does not pair/unpair a host or validate traditional lockdown pairing.
See [results and limits](../FOLLOWUP_567_20261116.md).

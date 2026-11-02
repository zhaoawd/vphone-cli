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
  geometry, and the last touch received by its window. Scene geometry changes
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

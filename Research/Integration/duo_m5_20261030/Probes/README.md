# Native Duo probes

The source files are copied unchanged from the experiment directory, with
SHA-256 provenance in `sources.json`. They contain no firmware, application
build products, or user account state.

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

Guest acceptance must install device IPAs through `ideviceinstaller` and
installd, then launch through `apps.launch`. Installing through `apps.install`
does not exercise the installd path. Use an isolated acceptance machine and
record the IPA hash and bundle ID alongside results.

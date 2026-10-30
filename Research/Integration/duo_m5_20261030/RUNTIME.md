# Isolated VM validation, 2026-10-30

The iPhone Duo integration remains on `duo-integration-20261030`. `main` and
`origin/main` remain at `39324ee7fcbb1d909bfa293f6188a8ef752ba734`.
There has been no remote push. The original `duo-m5-fold214` remains stopped.

## Experiment settings

The baseline and candidate use separate new-identity APFS clones of the same
stopped source. Their matching bundle's CFW update ran through the user's
Terminal. Both receipts have the same 54 Guest patches, with fold display and
guard enabled; the optional static-inner cutout library is not installed.
The VM binaries were admitted in that same user-executed root preparation.
See `runtime-preparation.json`, `validation.json`, and `ACCEPTANCE.md`.

Baseline code is upstream `39324ee7` (bundle build hash `d3af6081`, which adds
planning documents only). Candidate code is `a71f2360`. Later branch commits
record validation and scripts; these runs do not test a rebuilt binary from
those commits. Baseline and candidate fold-display libraries are byte-identical,
SHA-256 `a764b380db72e77a1d3c9f93fe84baafaa60666cf9d63b73db99211465f3295b`.
The old `fb41cd6b` previous-frame hold is inactive.

Only one clone runs at a time, headless, with its matching CLI and an explicit
machine library below this worktree's `.build`. Probe IPAs are the same
device builds in both runs. Installation uses `ideviceinstaller -u <UDID>`
and installd, followed by `apps.launch`; it does not use `apps.install`.
The new identities displayed a Trust This Computer prompt. Each clone was
paired to this host for the planned installation check; before/after images
and the tap replies are retained.

## Checks and evidence

| Check | Baseline | Candidate | Evidence / scope |
| --- | --- | --- | --- |
| First boot and daemon RPC | Passed | Passed | `baseline-boot-1`, `candidate-boot-1`; daemon binary hashes match their respective bundle resources. |
| Fold and rotation | Passed | Passed | `baseline-smoke-2`, `candidate-smoke-1`; six supported hinge/orientation combinations and six open/close cycles. |
| Unsupported physical poses | Passed | Passed | Cover upside-down and inner landscape-right return the exact upstream `invalid_operation` error and leave orientation unchanged. |
| Fold after screen off | Passed | Passed | Locked/off asserted before fold; locked asserted after opening; unlock then close succeeds. |
| SpringBoard/backboardd PID continuity | Passed | Passed | Compared before/after smoke and probe runs, without process restarts. |
| Five probe IPA installs | Passed | Passed | GeoProbe, GeoBare, KBProbe, KBProbeFS, Probe; install logs and IPA hashes retained. |
| CSSC correctness | Six passed | Six passed | Guest-produced JSON, not host-only execution. |
| App geometry collection | Eight samples | Eight samples | GeoProbe and GeoBare, closed/open-flat, portrait/landscape-left; positive scene/window dimensions asserted. |
| Focus and text across open/close | Four passed | Four passed | KBProbe and KBProbeFS: `first_responder=true`, exact text retained, visible window. |

Case paths above are relative to `.build/acceptance/cases/`. Raw replies,
screenshots, app-owned JSON, crash lists, signatures, and boot/stop logs stay
there. `runtime-validation.json` contains the small comparison results and
evidence hashes. `Regression/vm-run.zsh`, `vm-smoke.zsh`, and `probe-run.zsh`
are maintained entrypoints; a new evidence directory is required per run.

The supported rotation matrix comes from `setFoldableRotation` in
`VPhoneDaemon/Daemon/GuestAPI+Device.swift` and the CoreMotion relay's refusal
of physical upside-down orientation. Both hinge states request all four
interface orientations. Two combinations must fail with the specific error;
the other six must settle to the requested interface angle. The early smoke
attempt treated all eight as supported and stopped at the expected rejection;
its evidence is retained as `baseline-smoke-1`.

The first baseline probe installation succeeded. Its subsequent CSSC launch
was rejected after the VM auto-locked; unlock and relaunch succeeded. A second
probe run updated the still-running CSSC app and waited in installd. Normal
`apps.terminate` let that update complete. The maintained runner now terminates
only running test probes before updating them. The measurement/assertion
steps are unchanged from the successful baseline run. Driver hashes are
recorded with each probe run. The original baseline driver was reconstructed
by removing that setup change; its hash matches the recorded execution hash.
The preserved candidate driver also matches its recorded hash. Later helper
changes add binary pin checks, output restrictions and driver copies. They
passed syntax checks. `vm-run.zsh <variant> <new-case> --check` passed for
both bundles, verifying the root marker, pinned CLI/VM hashes and signatures
without launching another VM.

The host socket path is 127 characters, beyond the AF_UNIX address limit
for an absolute client address. The upstream server already supports this.
The acceptance client now connects using the socket basename from its
directory. A native one-request fixture tests success, empty reply, explicit
failure, malformed JSON, and a long absolute input path: five cases passed.
The RPC JSON encoder's five contract checks also passed. No production
transport or signed binary was changed for this harness repair.

## Findings and limits

App-owned geometry differs from the daemon's primary-screen dimensions on
the inner panel. For example, baseline GeoProbe reports a 669 × 951 point
scene/window in inner portrait, while `device.screen` reports the primary
466 × 678 point screen. These are separate measurements; primary-screen
coordinates must not be treated as the inner app's scene dimensions.

The inspected baseline KBProbe screenshots show the input text and caret
on both panels and no onscreen keyboard. Focus continuity is established by
the app's state file. Software keyboard presentation and hardware keyboard
event delivery remain separate checks. Nonzero geometry alone does not
establish safe-area or navigation-bar correctness.

Headless screenshots use the guest capture path. They do not validate the
window's physical display capture, host touch injection, privacy masking,
window-frame restoration, or the absence of transient black/stale frames.
The initial unqualified screenshot calls used the app's default Desktop
destination; those files were retained. Maintained captures now specify
paths inside the acceptance case explicitly.

Diagnostic lists include reports inherited from the source, including an
October 27 panic. Comparisons use before/after report names, rather than
treating every listed report as new. New SiriSearchFeedback reports occurred
on the baseline. Candidate smoke also added SiriSearchFeedback and
ReportSystemMemory reports; its probe run added ReportSystemMemory and
ExcUserFault_lsd reports. Triage in [DIAGNOSTICS.md](DIAGNOSTICS.md) found
none attributable to the candidate: SiriSearchFeedback is a parsecd session
log; the ReportSystemMemory crash has one signature on both builds and on the
source VM since Oct 27, near boot; the lsd fault is a simulated iconservices
fault that two candidate repeats did not reproduce. The recurring reporter
crash still prevents a claim of an entirely crash-free guest. No claim of application
stability outside the measured SpringBoard/backboardd PID checks is made.

Baseline and candidate app-owned scene/window/screen geometry and focused-field
measurements compare exactly across all eight geometry and four focus samples.
Both clones shut down normally after the checks. Neither is left running.
The final sampled guest uptimes were 1,461.8 seconds for baseline and 223.9
seconds for candidate. These observation intervals are unequal; this run does
not compare diagnostic-report rates or establish long-idle stability. Final
process checks found none of the recorded source/baseline/candidate VM PIDs,
and lsof found no open handles on their three disk images.

Remaining acceptance includes windowed F3/F5 input and video measurements,
safe-area assessment, keyboard modes, account-dependent application continuity,
audio, repeated cold boots, 120-minute idle, snapshot restoration, and a full
64 GB export/import followed by imported boot. Static outer/inner changes and
cutout patch on/off/on require separately prepared copies and root steps.
Host restart and additional host privilege changes remain approval gates.

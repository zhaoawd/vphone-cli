# Diagnostic report triage, 2026-10-30

`RUNTIME.md` listed SiriSearchFeedback, ReportSystemMemory and
ExcUserFault_lsd reports that appeared during the isolated runs without
a cause. This record reads their contents and repeats the conditions.
Report bodies were read with the `logs.crash` RPC from the stopped and
rebooted candidate clone. Raw files are below
`.build/acceptance/cases/candidate-diag-1/reports/`. They are not tracked.

## Result

None of the three is attributable to the candidate build.

| Report | Kind | Cause read from the report | Present before integration | On baseline build |
| --- | --- | --- | --- | --- |
| SiriSearchFeedback | `bug_type` 313, not a crash | parsecd search-feedback session log; the `agent` field names `safari/1` or `parsecd/1`. Smoke launches Safari. | Yes, Oct 27 and 29 on the source VM | Yes (`baseline-smoke-2`) |
| ReportSystemMemory | `bug_type` 309, the reporter process crashed | `EXC_BREAKPOINT` in `-[CDJetsamReport generateLogAtLevel:withBlock:]` → `OS_dispatch_semaphore.wait(wallTimeout:)`; ASI `BUG IN LIBDISPATCH: mach semaphore API failure`, `Abort Cause 53` | Yes, the same signature on Oct 27, Oct 29 and Oct 30 11:10 (source VM, old bundle) | Yes, three after its 15:33:13 boot |
| ExcUserFault_lsd | `bug_type` 308, `is_simulated: 1`, lightweight corpse; lsd was not terminated | `os_fault` from `com.apple.iconservices`: `Failed to get the icon cache path with error: %@` | No ExcUserFault_lsd in the source list; ExcUserFault_DockFolderViewService on Oct 27 is the same report class | Not seen |

### ReportSystemMemory

Every saved instance, Oct 27 to Oct 30 and on both builds, has the same
exception, ASI string and faulting frames. Abort cause 53 is
`KERN_DENIED` from the semaphore timed wait. The reporter dies while writing
a jetsam report, so the jetsam event itself has no report. The new runs
looked like a candidate addition only because of where the snapshots fell:
the baseline crashes happened 39 s, 81 s and 146 s after its boot,
before `baseline-smoke-2` took its "before" list. The candidate's came 43 s,
86 s and 138 s after its 15:57:57 boot, during smoke and probes.
The three boots in this triage (candidate 16:49:28 and 17:00:31,
baseline 16:57:19) produced none. The crash is intermittent, occurs near boot,
and predates this integration. The semaphore denial in the guest
was not traced further; this is a guest/platform issue, not Duo display code.

### ExcUserFault_lsd

Captured at system uptime 130 s while `candidate-probes-1` installed the
five probes. Repeats:

| Case | Build | Uptime at probe start | Result | New reports |
| --- | --- | --- | --- | --- |
| `candidate-probes-2` | candidate | ≈ 6 min | Passed | none |
| `baseline-probes-3` | baseline | ≈ 16 s | Installs passed; stopped at GeoProbe landscape-left rotation, `invalid_operation` | none |
| `baseline-probes-4` | baseline | ≈ 108 s | Passed | none |
| `candidate-probes-3` | candidate | ≈ 94 s, with 35 s lsd syslog | Passed | none |

The fault did not recur in two candidate repeats, including one matching the
original timing. The lsd syslog in `candidate-diag-2/lsd-syslog.json`
shows icon-service connections and no fault. It is a non-fatal, one-off
iconservices fault that these repeats could not reproduce. Nothing on the
Duo path writes icon caches. It stays recorded as unexplained, not as
build-attributed.

### Early rotation refusal

`baseline-probes-3` shows a separate early-boot limit: about 30 s after
boot, `display.rotation` returned "The device did not apply the requested
rotation." The same driver passed at about 108 s. Runners should wait
until SpringBoard has settled before rotation checks. This was seen on
the baseline, so it is not a candidate regression.

## Consequences

- The candidate is not claimed crash-free: the ReportSystemMemory crash
  occurs on both builds and on the source VM.
- Report comparisons must start their "before" list after a settled
  boot and compare equal observation windows. Otherwise a boot-time
  report appears to belong to the later step.
- SiriSearchFeedback is a session log and should be excluded from crash
  counts.

Report hashes (SHA-256, files under the evidence directory above):

```
888cb8fffe044785a4911c6aab7411fff833c65c5628beb1fb020ca70d591234  ExcUserFault_lsd-2026-10-30-160014.000.ips
619daa26c8fb52e321afffdec240e0f0fe6cf8a7ac163605b9998dd183c28c64  ReportSystemMemory-2026-10-30-155840.ips
837bb7907797df5adf51d32c64232fd0f6918b0b4679bd6ce30c15c5e3a851c3  ReportSystemMemory-2026-10-30-155923.ips
d8ec123e535d5939580f3766c4472ebee6fc68a376ed834360493e23a6e3fd5c  ReportSystemMemory-2026-10-30-160015.ips
dc76df1ea044f9d44cead1721465cef312053ae4ba264738c61712e5602f2f5a  ReportSystemMemory-2026-10-30-111025.ips
47111cbc4efeb2dffad7b4d3744065d9bb7c7f34afac076743e6e0db58b3e73e  ReportSystemMemory-2026-10-29-235536.000.ips
3d837775a9e32d2e3ba5fb98470a5a04a8778189b517e1b4d4a798ad1519db70  ReportSystemMemory-2026-10-29-230517.000.ips
8ce2cb00f96223c7afaa65d3b6ae46a9107f25c13f1d05dc98dea5e7bae7263d  ReportSystemMemory-2026-10-27-174334.ips
```

Both clones were stopped normally after these runs.

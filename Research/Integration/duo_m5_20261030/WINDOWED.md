# Windowed F3/F4/F5 validation, 2026-10-30

Both isolated clones were launched with a window (`vm-run.zsh <variant>
<case> --windowed`), one at a time, with the same pinned bundles as
`RUNTIME.md`. Host taps and swipes go through the VM view (VZ touchscreen).
Recordings come from the window's own recorder (Capture > Start Recording),
which records the presentation graphics output. The recorder is driven
through Accessibility menu presses, so no keystrokes reach another app.
Evidence is below `.build/acceptance/cases/`; recordings are not tracked.

| Case | Script | Recording SHA-256 prefix |
| --- | --- | --- |
| `candidate-f5-1`, `baseline-f5-1` | `Regression/f5-record.zsh`, `f5-analyze.zsh` | `619ba19d542615fe`, `212b8f2f355c2ac6` |
| `candidate-f3-1`, `baseline-f3-1` | `Regression/f3-touch.zsh` | — |
| `candidate-edge-1`, `baseline-edge-1` | `Regression/f3-edge.zsh` | — |
| `candidate-f4-1`, `baseline-f4-1` | `Regression/f4-power.zsh` | `8cb940f5dce5a434`, `6902f65ac2f8f9fe` |

`candidate-f5-1-aborted` holds the first recorder attempt, which stopped at
a script error before any action; its recording is not analysed.

## F3 touch mapping

Five points per posture × orientation through vphoned `input.tap` and the
window's host `tap`, against the preserved touch page in Safari:

- Baseline and candidate `result.tsv` are identical: all 80 taps, every
  injected point, received client point and viewport.
- Closed: 40/40 delivered; constant offsets on both paths (0, or −84 pt in
  landscape-right for Safari's safe area). This matches v1.6.
- Open-flat: 40/40 delivered; injection is in primary-panel points and lands
  linearly scaled on the inner display, x 1.435 / y 1.404 (axes swapped in
  landscape), residual ≤ 0.17 pt, with Safari's −80 pt toolbar offset.
  v1.6 recorded the same scale with residual ≤ 0.4 pt.
- Inner landscape-right is refused with `the host controls have no
  upside-down orientation` on both builds, as in headless smoke. v1.6 had all
  four inner rotations; this is current upstream behaviour, not a candidate
  change. Those taps ran in landscape-left.

## F3 edge gestures

From Settings, swipe up from the bottom edge, three trials per path:

| Path | Closed | Open |
| --- | --- | --- |
| Host `swipe` (window) | 3/3 | 3/3 |
| vphoned `input.touch` with `edge: 2` | 3/3 | 3/3 |
| vphoned `input.swipe` (no edge flags) | 0/3 | 0/3 |

Both builds give the same table. v1.6 recorded `edge: 2` as 0/3 on the inner
display; current upstream reaches both. A plain `input.swipe` carries no edge
flags and does not trigger the system gesture on either display.

## F5 transition frames

Fixed sequence: six Home-screen open/close cycles, Safari, Settings and
Photos across folds, cover/inner rotation, four 1 s rapid cycles, and a
power press 0.1 s after a close. 30 fps, 1398 × 2034, about 150 s each.
The current upstream FoldDisplay log has one-second wall-clock times, so
frames cannot be aligned to guest hand-over events. Attribution to actions
uses the v1.6 recorder lag of 0.7 s and is uncertain by about ±0.3 s. Counts
use frames at least 99% black, since the 24-luma black threshold also counts
the touch page's dark background.

| Fully black frames | Candidate | Baseline |
| --- | --- | --- |
| Total | 72 | 66 |
| Home-screen open/close, each | 1–3 | 1–4 |
| Safari open on inner | 5–6 | 3–9 |
| Rapid (1 s) open | 4–5 | 4–12 |

Most fold hand-overs on both builds pass through 1–12 fully black frames
(33–400 ms), followed by a fade-in. A few have none attributed to them. App launch cards add their own dark
frames. The fold-display libraries are byte-identical, and the difference
between builds is within run-to-run variation. Current upstream reduces
the v1.5 gaps (Home 6–7 frames, Safari 11–30) but does not remove them. With
the v1.6 hold (`fb41cd6b`), hand-over black frames were 0 at a cost of
260–420 ms static frame, or 0.9–1.4 s with Safari in front.

## F4 power during a close

`f4-power.zsh`, five trials per build: Safari (touch page) on the inner
display, close, power 0.1 s later, wake by opening after 4 s.

- No trial on either build shows Safari on the cover after the press.
  Every trial ends on the cover lock screen.
- `device.screen` after 1 s: locked and screen on in 10/10, as recorded in
  v1.6 s6 (the screen relights on the lock screen). After the wake: locked
  in 10/10.
- In the earlier F5 runs, the baseline showed one Safari frame on the
  cover about 0.1 s after the press. The recorder then repeated that frame
  while the output was idle, until the lock screen. The candidate F5 run
  went straight to the lock screen. The repeated trials did not reproduce
  the Safari cover frame on either build.
- Consistent per-build difference with no established cause: before the
  lock screen fades in, the baseline output holds inner Safari partly faded
  (about 20 frames, 22% black) in 5/5 trials, while the candidate holds a
  fully black frame (17–19 frames) in 5/5. The candidate's host changes
  (window frame restore, display choice) and guest SystemHook change (an
  `access()` check before loading the fold display) do not touch presentation.
  The close mark's position relative to these frames also differs by about
  200 ms between the two runs. A per-clone state or timing difference is
  not excluded.

## Process and report checks

SpringBoard/backboardd PIDs were unchanged across both F5 runs. The
candidate F5 added two SiriSearchFeedback session logs (Safari launches);
the baseline added none. See `DIAGNOSTICS.md` for that report type.

## Decision input for `fb41cd6b`

Current upstream still shows black hand-over frames on both builds, at the
same rate. Adapting the hold would remove them at the cost of a short static
frame. The F4 trials found no unlocked app content after a power press
without the hold. With the hold, that check must be repeated, together with
v1.6's s1–s9 lock cases.

User decision, 2026-10-30: do not adapt `fb41cd6b` for this integration.
The hold stays in source history only; the candidate keeps upstream's
hand-over behaviour, including the measured black frames.

## F2 keyboard modes

`Regression/kb-modes.zsh`, KBProbe and KBProbeFS (`UIRequiresFullScreen`
true), starting on each display, in two modes:

- Hardware: the field is focused by a window tap and typed through the
  window's host key path (`hostkey`, the events a Mac keyboard sends).
- Software: bit 0 of `GSEventHardwareKeyboardAttached` is cleared, as
  Device > Toggle Software Keyboard does, and keys are tapped on the guest
  keyboard. The original state is restored afterwards (checked:
  `keyboard-state-final.txt`).

Each case then opens/closes with the field focused. Candidate
(`candidate-kb-3`) and baseline (`baseline-kb-1`) tables are identical
apart from the AX key count:

- 8/8 cases: after each fold the field is still first responder and keeps
  its text (`Hw` hardware, `Sw` software; the first letter is capitalised by
  autocapitalisation), window visible, scene 466 × 678 on the cover and
  951 × 669 / 669 × 951 on the inner display.
- Screenshots after all 16 folds: no software keyboard in hardware mode;
  the software keyboard on the current display in software mode, with the
  app's bottom marker still drawn.
- The AX tree reports keyboard keys in hardware mode too, so the key count
  is not used for visibility.

Automation finding (both builds; vphoned is unchanged): on the inner
display `ui.tap_element` returns the element centre in inner-display points
but injects it as primary-panel points, which the F3 scale (×1.435 / ×1.404)
then moves. Candidate run 1 missed a field at y 102–146 (tap at y 124 →
≈ 174); the baseline hit a field at y 20–64 (y 42 → ≈ 59). The runner taps
through the window instead, from the element's fraction of the app scene.

## Window frame restore

`Regression/window-frame.zsh` reads the window frame through Accessibility
at each launch (`.build/acceptance/cases/window-restore/`):

| Launch | Baseline window | Candidate window |
| --- | --- | --- |
| 1 | 444 × 698 | 488 × 762 |
| 2 | 422 × 666 | 390 × 619 |
| 3 | 400 × 634 | 390 × 619 |
| 4–5 (from a 488 × 762 window) | — | 488 × 762, 488 × 762 |

The baseline loses about 32 pt of height and 22 pt of width per relaunch,
the toolbar-height loss that integrated commit `78b79d0f` fixes. The
candidate restores the same frame on every relaunch measured. Its one change,
488 → 390 between launches 1 and 2 after the keyboard session, was not
reproduced by folds, inner portrait rotation, or relaunches from either size.
It remains unexplained.

Within a session a user-set 488 × 762 window returns to the same size after
open/close on the candidate. The window takes up to 5 s to follow a fold; 3 s
samples sometimes still showed the previous shape. At odd window
dimensions the origin moves (−1, +1) pt per rotation on both builds
(baseline at 389 × 618: 155,44 → 152,47 over three cycles). This is
upstream re-centring rounding, not a candidate change.

## Not covered

Safe-area/navigation-bar correctness, account-dependent app
continuity, audio, networking, long idle, snapshots, full export/import,
static display changes and cutout on/off.

# Steam Controller pad: jitter while the thumb moves — November 13, 2026

Follows the resting-thumb fix of the same day (`handoff-2026-11-13.md`). Report: "Now it only jiggles while I move
my thumb on the trackpad. Stays still while still", and it must stay "a very responsive trackpad".

Scope: `PadSteamTrackpad` (both pads, trackball and trackpad mouse, every profile). Status: the filter is **confirmed by the user** ("it is smoother… the jiggling is gone"); the Mac-pointer
fix further down is **confirmed by the user** too ("Smooth now").

## Evidence

`docs/investigations/data/steam-right-pad-2026-11-13.txt` (2,045 touched reports, about 125/s, original Steam
Controller on its cable, the user's profile with movement haptics on). "True" path for the analysis: a quadratic
fitted to ±40 ms around each report (not causal, analysis only). Residuals from it, per axis, part of the pad:

| Finger speed (pad/s) | reports | x | y |
|---|---|---|---|
| under 0.05 (resting) | 854 | 0.0018 | 0.0028 |
| 0.05–0.2 | 754 | 0.0018 | 0.0030 |
| 0.2–0.5 | 121 | 0.0022 | 0.0028 |
| 0.5–1 | 144 | 0.0023 | 0.0025 |
| 1–2 | 106 | 0.0039 | 0.0025 |
| over 2 | 30 | 0.0058 | 0.0030 |

(The rise above 1 pad/s is at least partly the quadratic not following a fast curve, not noise.)

- **Haptics are not the cause (verified from the data).** The cursor is still while resting, so no movement
  haptics fire there, yet the noise is the same as during slow and medium movement, when they do. The residuals'
  autocorrelation falls to about −0.2 at one and two reports and is within ±0.1 from 5 reports on, with nothing
  near 10 reports (the haptics' 12.8 Hz). No on/off recording was needed.
- The noise is close to white, so a low-pass removes it; the question is only what lag is acceptable where.

## Comparison (offline replay of the recording, user's sensitivity ≈ 1,370 px/pad)

Jitter: RMS change of the error against the "true" path from one report to the next (the true path keeps some
noise itself, so the floor is not 0). Lag: along-track distance behind ÷ speed. Swipe: px behind at the end of a
clean 2.5 pad/s swipe (sensitivity 1,000). Overshoot: px past the finger after it stops.

| Filter | jitter 0.05–0.2 | lag 0.05–0.2 | jitter 0.6–1.5 | lag 0.6–1.5 | lag >1.5 | swipe | overshoot |
|---|---|---|---|---|---|---|---|
| raw | 7.9 px | 0 | 8.5 | 0 | 0 | 0 | 0 |
| low-pass 30 Hz | 4.2 | 6 ms | 4.7 | 5.5 ms | 5.5 ms | 13 px | 0 |
| low-pass 15 Hz | 3.1 | 10 ms | 4.0 | 11 ms | 11 ms | 27 px | 0 |
| least-squares line, 40 ms, endpoint | 3.9 | 0 | 4.3 | 0 | 1 ms | 0 | **11 px** |
| least-squares line, 100 ms | 2.7 | — | 5.7 | 3 ms | 6 ms | 0 | **32 px** |
| One Euro 1 Hz + 20·v, speed at 1 Hz | 2.1 | 12 ms | 4.5 | 8 ms | 7 ms | 7 px | 0 |
| One Euro 3 Hz + 60·v, speed at 10 Hz | 3.3 | 8.5 ms | 6.6 | 2.3 ms | 1.2 ms | 2.3 px | 0 |
| **chosen**: 4 Hz + 80·(v − 60·noise), speed at 15 Hz | 3.6 | 9 ms | 6.7 | 2.8 ms | 1.1 ms | 2 px | 0 |

Rejected: the plain low-pass (lags a swipe as much as a slow aim); straight-line prediction (no lag at constant
speed, but it runs past a finger that stops and comes back, which a trackball's momentum would then launch from);
alpha-beta is the same class; One Euro with its usual slow speed estimate (opens late on a swipe). A median of
three was set up but not measured.

## What was built

- `noiseLevel`: the scatter of the last 80 ms of readings around a straight line, averaged (5 % a report; 1 % upward
  while the finger is moving, because a curve also scatters). Kept across touches; 0 after a reset, so the first
  second on a noisy pad is unfiltered.
- Filter weight 0 below 0.0008 (raw: quiet pads and all the earlier synthetic tests are unchanged), 1 from 0.002.
  The recorded pad sits around 0.003.
- Cutoff 4 Hz + 80 Hz per pad/s of finger speed beyond 60 × noiseLevel. The same speed now drives the Smoothing
  setting's cutoff; the stronger of the two filters applies. With Smoothing 0 there is no landing ease-in, as before.
- First attempt at the noise level (down fast 20 %, up 2 %) rode the low side of the scatter (median 0.0025) and
  left the filter partly off; replaced by the averaging above.

## Results (tests)

- `MovingThumbTests.testTheRecordedMovingThumbJittersFarLess` (15.6 s of the recording, the user's settings):
  step-to-step change per report, slow movement (under 0.5 pad/s, 162 reports) 11.6 → 3.8 px; faster (225
  reports) 12.4 → 10.0 px; total travel within 25 px of the raw readings'.
- `testASwipeOnANoisyPadIsNotHeldBack`: under 12 px behind at the stop of a 2.5 pad/s swipe with ±0.0045 noise,
  under 6 px past it afterwards. `testAQuietPadStaysRaw`: exact raw steps without noise.
- Existing `SteamPadFeelTests`, `SteamPadSteadinessTests`, `TrackballRestTests`, `RecordedRestingThumbTests` pass
  unchanged.

## Open

- User confirmation on the controller. If mid-speed movement (0.5–1.5 pad/s) still looks rough, the lever is
  `noiseOpening` (80 → 40 roughly halves the opening: about 3.5 ms at 1 pad/s instead of under 2).
- Fresh install and migration: nothing stored changes; profiles and settings are untouched. Undo: none needed.
- Untried: the controller's own smoothing setting (`SETTING_SMOOTH_ABSOLUTE_MOUSE`).

## Follow-up the same evening: smooth in a stream, choppy on the Mac desktop

User, after installing the filter: "It feels much better through a stream than it does on MacOS itself. on MacOS
the movement is choppy, on my stream the movement is smooth. But the jiggling is gone at least."

Measurement (read-only, alongside Nokcandu): the pad recorder with absolute timestamps and a poller logging the
pointer position every 0.5 ms whenever it changed, about 20 s of touched movement. Displays: built-in 60 Hz,
external 120 Hz; the pad reports every 8 or 12 ms (about 111 a second).

- 795 of 2,921 pointer changes while touched came less than 2 ms after the previous one. A typical report:
  pointer +52.5 px, then 0.6 ms later −53.5 px. The second change is the gyro's move (the profile aims with the
  gyro; its steps are a few whole pixels) posted from the position macOS still reported from before the trackpad's
  move. Steps under 2.5 px survived, which is why slow movement worked and faster movement stuttered.
- Cause and fix: see engineering-learnings, "A posted pointer move isn't visible at once". `PadPointerContinuity`
  replaces the 2.5 px test in `DesktopPad.move`.
- Considered and not the cause: the display refresh against the report rate (it would affect the stream the same
  way); main-thread delays (pointer changes followed reports within about 0.5 ms throughout).
- The user confirmed the Mac pointer is smooth after installing the fix. No recording was made after it.

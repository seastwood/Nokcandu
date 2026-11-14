# Gyro drift: quicker, quieter automatic calibration — November 13, 2026

Request: "We need the gyro calibration to occur automatically more frequently. Like it needs to start after not
sensing movement for like 5 seconds or something... or do it smartly in such a way that isn't showing up on my
screen all the time. I just want it to be able to fix drift much more quickly", and then: "it also seems to lose
its calibration randomly... like it already had it calibrated really well".

Scope: the shared profile engine (`Sources/NokcanduPadEngine/padengine.c`: every controller with a gyro, the Mac
desktop, streams and Windows games), `DesktopPad` (carry-over), two labels. Status: **built and tested; not yet
confirmed by the user.**

## Evidence

`data/steam-pad-gyro-in-hand-2026-11-13.txt`: 300 s of the original Steam Controller on its cable, hand-held in
normal use (recorded read-only for the pointer investigation; columns as in the recorder's header, gyro raw ×
2000/32768 = degrees/s). Per 2 s window:

- quiet windows: average change between reports 0.3–0.7 degrees/s (largest 0.85–1.5), standard deviation
  0.3–1.9 per axis, and the window's average anywhere from −0.5 to +2.3 on x while the true drift was about +0.4.
- so the old test for "put down" (change under 1 degree/s between reports for 1.5 s) is passed by a calm hand,
  and the 1.5 s average taken then can be a degree per second off. That is the calibration "lost randomly".

Offline trial of rules on that recording (gyro only):

| Rule | accepted | values (x, y, z) |
|---|---|---|
| 5 s, half-second averages within 1.2 | 1 | +0.38 −0.57 +0.35 |
| 5 s, within 0.8 | 0 | — |
| 3 s, within 1.0 | 5 | one at +1.74 +0.14 −0.08 (wrong by 1.3), the others within 0.3 of each other |

The user was not trying to hold still in this recording, so one acceptance in 300 s is the careless-use rate, not
the rate when the controller is held or put down for 5 s on purpose (synthetic tests cover that).

## Built

See engineering-learnings, "Gyro drift: a hand is not a table". Constants in `padengine.c`: `QUIET_TIME` 5 s,
`QUIET_BLOCK` 0.5 s, `QUIET_SPREAD` 1.2, `QUIET_BAND` 5, `QUIET_OFF` 8, `QUIET_TIP` cos 2°, `CAL_NOTICE` 1
(degrees/s).

## Not done / open

- Confirmation on the controller, in the hand and put down.
- No recording yet of the controller lying on a table (its noise floor), nor of a deliberate slow even turn; if
  drift corrections are still too rare in real use, `QUIET_SPREAD` is the lever, and the 3 s row above is the
  warning against shortening the time.
- Windows games' own engines (controllers Nokcandu doesn't read itself) start without a resting reading at each
  game start; persisting it per controller would fix that.
- Fresh install and migration: nothing stored changes. Undo: turn off "Keep the gyro calibrated automatically"
  in the profile's gyro settings (the same stored switch as before).

## Later the same evening

- The first version let only quiet tracking replace a resting reading. `GyroDriftRecoveryTests` (a bad first
  measurement, then exactly 5 s put down) failed: recovery had gone from 3 s to more than 5. The quick
  measurement was restored for a controller that is really put down (`TABLE_RANGE` 1 degree/s over its 1.5 s,
  gravity steady), every 5 s at most.
- The user also asked why the layer changes on a window switch: a separate cause in the same engine
  (`pe_release_all` on focus change); see engineering-learnings, "A window switch lets go of outputs".

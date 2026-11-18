# Steam Controller (2026)

November 18: opt-in absolute pad regions, recorded/drawn gestures, trigger modes, alternate menus and
local DSU motion are implemented. See [setup, scope, migration and verification limits](advanced-controller-remapping.md).

Read by the same reader as the original (`SteamControllerUSB`, the profile's "Steam Controller, read directly"
input), over USB (product 0x1302), Bluetooth (0x1303) or the Steam Controller Puck (0x1304 or 0x1305, one
controller per HID interface 2–5). Added November 15, 2026, **without the controller to test against**; the
protocol follows Valve's SDL driver (`src/joystick/hidapi/SDL_hidapi_steam_triton.c` and
`steam/controller_structs.h`, where it is called Triton).

## Protocol

- Input: plain numbered HID reports — 0x42 (state), 0x45 (state over Bluetooth, same layout), 0x47 (state with a
  trackpad timestamp, pads two bytes later), 0x43 battery, 0x46/0x79 Puck connect/disconnect.
- State: sequence, 32 button bits, triggers (0…32767), both sticks, both pads (x, y, pressure), motion
  (accelerometer, gyro). `SteamController2026.decode` gives the same `SteamControllerReport.State` as the original
  with `kind = .steam2026`, `rightStick` and pad pressures added; the gyro's y is flipped so it reads in the
  original's axes (SDL gives the original's as x, z, y and this one's as x, z, −y).
- Desktop mode ("lizard mode") off and raw motion on: feature report 1, set settings 9 = 0 and 48 = 0x18, sent
  again every 2 s. There is no mode to restore: the controller goes back to its own a few seconds after the last.
- Haptics: output reports — 0x81 pulse (the original's pulse fields: side, on µs, off µs, repeats), 0x80 grip
  rumble (resent every 40 ms; the controller stops after about 50 ms).
- Which interface is the controller's is decided by its reports: the first interface to send a state report
  while nothing else is being read is taken over.

## Inputs

ABXY, d-pad, bumpers, triggers (a trigger's click is a full pull), View (`back`), Menu (`start`), Steam
(`guide`), QAM (`misc`), stick clicks, L4/L5/R4/R5 (`paddle2`, `paddle4`, `paddle1`, `paddle3`), left pad click
(`touchpad`) and four inputs of its own: `rpclick` (right pad click), `lgrip`/`rgrip` (Grip Sense) and
`lstouch`/`rstouch` (a thumb on a stick). Set Grip Sense to "Gyro on" for gyro only while held.

Both trackpads use the full trackpad settings. The right stick is a real stick; a right pad set to the right
stick takes over only while pushed further.

## Not yet checked on hardware

SDL's naming of View/Menu (it sends Menu as Back), the haptic pulse's side numbering (assumed as the
original's: left 1, right 0), whether a pulse feels right, and the picture's exact proportions.

## Picture, pad angle and ownership (November 17)

The supplied front-on reference now informs a separate diagram: ABXY mirrors the D-pad, pad surfaces lean
inward by ±10°, stick callouts sit outward/below with leaders, cardinal captions surround their buttons, and
gyro sits below the body. All mapping captions have bounded wrapping/truncation and full hover text. Geometry
checks cover 320–800 point widths; SwiftUI previews at 320 and 560 were visually inspected. Exact hardware
proportions remain unmeasured. Presentation tilt does not change input calibration.

The first diagram still put the pads too low, crossing the inner shell cutout despite passing canvas and
caption checks. The user's follow-up corrected this: photo landmarks place pad centers at about 55% of shell
height (was 68%), sticks at 26% (was 38%), and QAM level with the pads. Pad size is now about 23% of shell width,
with a shallower, flatter inner opening and fuller lower grips. Upper button/header sizes and positions also
follow the reference more closely. The renderer and regression tests now share the actual shell path;
expanded, rotated pad perimeters must stay inside it with clearance. Long-label lanes remain separate.

**Pad angle** is now shared by every behavior, including Scroll wheel (circle) and Existing mappings. Left
pad defaults to 0° (straight axes). Explicit saved angles remain intact, tap/click zones rotate in every
behavior, and circular scroll direction/step count remain invariant. Existing touch/right-pad axes now honor
the angle too; the 2026 physical stick remains independent.

The direct reader now requests exclusive HID access for the app's lifetime when the global Controller
ownership option is enabled (default On), reports refused access, and releases on quit/opt-out. Physical
2026/Puck acceptance with native Steam remains pending; other controllers are not made exclusive by this
setting. [Evidence, migration and Undo](investigations/controller-ownership-and-picture-2026-11-17.md).

# Handoff: new controller support (for review and release)

Written November 16, 2026, at the end of the session that added it. Scope: only the new controller support,
commits `7c9b6a5`…`d36be36` on `main` (after v0.14.2). Version is still 0.14.2; no release notes yet.

**Nothing here has touched real hardware** except the original Steam Controller (unchanged paths). Every driver
follows SDL's HIDAPI driver for that controller (`src/joystick/hidapi/SDL_hidapi_*.c`, zlib) and SDL_GameControllerDB
(zlib, Mac lines embedded in `GameControllerDBData.swift`). 812 tests pass (`swift test`), app builds and installs.

## What to review

| Area | Files | Reference (SDL) |
| --- | --- | --- |
| Steam Controller (2026): USB, Puck, BLE; picture; stick touch, Grip Sense | `SteamController2026.swift`, `SteamControllerUSB.swift`, `ControllerPicture.swift` (`steam2026Layout`, `Steam2026Shape`), `PadProfiles.swift`, padengine inputs `PE_RPAD_CLICK…PE_RS_TOUCH` | `steam_triton` |
| Community mappings for unknown pads; guessed layout | `GamepadMapping.swift`, `GameControllerDBData.swift`, `MappedGamepads.swift` | gamecontrollerdb |
| PS3 by USB (start feature F4) | `MappedGamepads.refresh` | `ps3` |
| Switch 2 Pro, GameCube (Switch 2), Joy-Con 2 by USB; rumble | `Switch2Controller.swift`, `Switch2USB.swift` | `switch2` |
| Xbox 360 wired, Xbox One/Series wired (GIP), 360 Wireless Receiver | `XInputController.swift`, `XInputUSB.swift` | `xbox360`, `xbox360w`, `xboxone` |
| GameCube adapter (057E:0337) | `GameCubeAdapter.swift`, `GameCubeAdapterHID.swift` | `gamecube` |
| Report-driven pads: 8BitDo, Stadia, Luna, SInput, ZUIKI, HORI Steam, GameSir 8K, SHIELD, Wii/Wii U Pro, PS4/PS5-compatible | `ReportPads.swift`, `EightBitDoController.swift`, `WiiController.swift`, `ReportPadsHID.swift` | `8bitdo`, `stadia`, `luna`, `sinput`, `zuiki`, `steam_hori`, `gamesir`, `shield`, `wii`, `ps4`, `ps5` |
| Per-controller rumble and motion; stream players | `MappedGamepads.rumble/publishMotion`, `HIDOutput.swift`, `Streams/StreamInput.swift`, `DesktopPad.swift` (`rumbleMain`, mapped motion) | — |
| Tests | `Tests/NokcanduCoreTests/Switch2ControllerTests.swift` (most decoder tests live here), `GamepadMappingTests`, `SteamController2026Tests` | — |

User-facing summary table: `docs/more-controllers.md`; Switch 2 details: `docs/switch-2-controllers.md`;
Steam Controller 2026: `docs/steam-controller-2026.md`.

## How it fits together

- Every driver publishes a controller to `MappedGamepads` under a source name: `hidmap:<id>` (community mapping),
  `xinput:<id>`, `switch2:<id>`, `gamecube:<id>:<port>`, `report:<id>`. Buttons are `PadProfiles.Input`, axes are
  SDL's order (0–3 sticks, y down, ±32767; 4–5 triggers 0…32767). Motion: `publishMotion(source, gyro rad/s,
  accel g)` in Nokcandu's axes, published **before** the buttons so a stream knows at arrival that it has motion.
- Axis conversion rule used everywhere: Nokcandu's axes = SDL's (x, z, y), from SDL's own mapping of the original
  Steam Controller. Each decoder's comment states the SDL formula it starts from.
- `ReportPadsHID` only takes a controller from the generic mapping after a report decodes (`claimed`). It sends
  nothing (no mode switch, no feature read) to a device macOS's GameController reads (`info.gamepad`) or a profile
  reads as its own device.
- Output reports go through `HIDOutput` (serial background queue): a Bluetooth device slow to accept one can't
  block the main thread.
- Desktop: all mapped sources feed the profile's controller; rumble goes to all of them, or only player one's when
  a stream sends the others as their own players. Stream: each mapped source is its own Moonlight player, with its
  own rumble (`pulseRumble`) and motion (`listenMotion`), gyro caps at arrival from `motionSources`.

## Known risks, worth checking first

1. **GameSir**: switched to its full mode (output 0xA2 01 00) at start. If the report format were wrong it would
   stop sending standard reports until replugged. Only sent when macOS doesn't read it.
2. **Gyro/accel signs and axis order** for each new driver: derived from SDL's formulas, not observed. The most
   likely class of bug is a mirrored or swapped axis.
3. **Wii conversation** (`WiiController`): extension reset → identify → MotionPlus check/activate → reporting mode.
   A stall leaves the remote unclaimed (falls back to generic mapping). Status reports while MotionPlus is on are
   ignored for extension changes (as SDL does).
4. **Switch 2 rumble** is sent from the input-report callback at most every 12 ms; stop is one report with zero
   amplitude. Joy-Con 2 pair = first left + first right connected.
5. **PS4/PS5 IDs** include Sony's own; those are left to macOS (not claimed). Rumble is the USB report only.
6. `Switch2USB.startUp` now matches interface 1 by `locationID` first (falls back to the first match).
7. Fixed in this work: Switch 2 acceleration y sign (now `-0x33`, matching the gyro's rule).

## Not done (deliberately)

Flydigi's own protocol (needs a setting in Flydigi's Windows app), SHIELD 2017 rumble (SDL: commands hang on
macOS), PlayStation Bluetooth rumble, touchpad positions for mapped controllers (click only), pictures for the new
controllers (they use the generic picture), Logitech wheel force feedback.

## To finalize for release

1. Review the list above; `swift test`; `./build-app.sh`.
2. With any controller at hand: plug in, read `~/Library/Logs/Nokcandu/Controllers.log` (driver, "read with its own
   report", "(gyro on)"), then buttons, stick directions, gyro direction, rumble in the controller tester and in a
   stream with two controllers.
3. Release notes `release-notes/v0.15.0.md` (suggested: this is a feature release), bump `VERSION`, tag. Earlier
   release notes are in `release-notes/` for the format.
4. Note: v0.14.2's tag was never pushed (`git tag v0.14.2 <its commit> && git push origin v0.14.2`).

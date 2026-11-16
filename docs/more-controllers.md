# More controllers

Controllers Nokcandu reads with drivers of its own, beyond what macOS's controller support knows. Added November
15–16, 2026, **without the controllers to test against**; each protocol follows SDL's HIDAPI driver for it
(`src/joystick/hidapi/`). Every one is published through `MappedGamepads`, so it works in profiles like any
controller and is its own player in a stream. A controller macOS's own support reads, or one a profile reads as
its own device ("Add Device"), is left alone.

| Controller | IDs | How | What it adds |
| --- | --- | --- | --- |
| Generic / third-party HID gamepads | any | SDL_GameControllerDB (Mac lines, `GamepadMapping`), else a guessed layout | works at all |
| PlayStation 3 controller | 054C:0268 | mapping + start feature report F4 | starts sending |
| Switch 2 Pro, GameCube (Switch 2), Joy-Con 2 | 057E:2069, 2073, 2066/2067 | `Switch2USB` (see switch-2-controllers.md) | full support by USB, rumble; a left and right Joy-Con 2 are one controller |
| Xbox 360 / Xbox One wired (and clones) | XInput / GIP class | `XInputUSB` (IOUSBHost) | works at all, rumble |
| Xbox 360 Wireless Receiver (and clones) | XInput class, protocol 0x81 | `XInputUSB` | up to four wireless 360 controllers, slot lights, rumble |
| GameCube adapter (Wii U / Switch) | 057E:0337 | `GameCubeAdapterHID` | four ports, four players, rumble (with its power plug in) |
| 8BitDo SF30/SN30 Pro, Pro 2/3, Ultimate 2/2C/3 (D-input) | 2DC8:… | `ReportPadsHID` | back buttons, Share, gyro, rumble |
| Google Stadia | 18D1:9400 | `ReportPadsHID` | Capture (Share), Assistant (paddle 1), rumble |
| Amazon Luna | 1949:0419, 0171:0419 (BT) | `ReportPadsHID` | microphone button (Share), Home over BT, rumble over BT |
| ZUIKI EVOTOP (PC, 2.4 GHz, Bluetooth), EVOTOP AXIS, MASCON PRO | 33DD:… | `ReportPadsHID` | gyro on the EVOTOP, rumble |
| HORI Wireless HORIPAD for Steam | 0F0D:01AB, 0196 (BT) | `ReportPadsHID` | M1/M2 and FL/FR back buttons, Quick Access (Share), stick touch, gyro |
| GameSir G7 Pro 8K, Tarantula 8K | 3537:10B8, 103C | `ReportPadsHID` (switches it to its full mode) | L4/R4, L5/R5, Share, gyro, rumble |
| NVIDIA SHIELD controller (2015, 2017) | 0955:7210, 7214 | `ReportPadsHID` | + and − (paddles), touchpad click, rumble on the 2015 one |
| Wii Remote (alone, + Nunchuk, + Classic Controller), Wii U Pro Controller | 057E:0306, 0330 (Bluetooth) | `ReportPadsHID` + `WiiController` (identifies the extension, sets the report mode) | works at all, accelerometer, MotionPlus gyro (remote alone), rumble (on/off) |
| PlayStation 4/5-compatible controllers macOS doesn't read (HORI, Nacon, Razer, PDP, Mad Catz…) | SDL's list | `ReportPadsHID` | gyro, touchpad click, mute (PS5) as Share, rumble by USB |
| SInput (GP2040-CE, Handheld Legend ProGCC/GC Ultimate, Firebird…) | 2E8A:10C6/10DF/10DD/10E0/10E5, 38D2:1014 | `ReportPadsHID` | paddles, Capture, touchpad click, gyro, rumble |

`ReportPadsHID` takes a controller from the generic mapping only once a report it understands arrives, so a
controller in some other mode keeps working as a mapped one.

macOS's controller support can connect a controller a moment after its HID device appears. So `ReportPadsHID`
waits a second before it sends a controller's start-up (mode switch, feature read, the Wii conversation), and
whenever the devices change it gives up any controller macOS has since taken (`recheck`); such a controller's
reports are then skipped without being decoded. (Review, November 16, 2026: before this a controller claimed in
that moment stayed claimed and would have been read twice. Not observed on hardware.) "macOS reads it" is decided
by the HID product name matching the `GCController`'s name (`HIDDevices.renumber`): a controller whose two names
differ would be read by both. Unverified for the DualShock 4 — check its lines in Controllers.log.

Every decoder, start-up command and rumble report was then compared with SDL's source line by line (November 16,
2026). Two differences were found and corrected: the 8BitDo Ultimate 2C's two back buttons were swapped (SDL reads
them as L4 0x04 / R4 0x20, the other models as PL 0x20 / PR 0x04), and the Steam Controller (2026) keep-alive was
65 bytes where SDL sends 64 including the report number. Everything else matched; `ControllerDriverLayoutTests`
holds the checks. Still unverified on hardware.

`XInputUSB` reads 64 bytes at a time (a whole packet): with the earlier 32, a longer GIP message would have ended
the read as if the controller had been unplugged.

Rumble and motion are per controller: in a stream each player's controller gets the host's rumble for that player
and sends its own gyro; at the desktop the profile's rumble goes to the controllers that feed it. Output reports go
out on a queue of their own, so a slow Bluetooth controller never holds the app up. Not done: SHIELD (2017) rumble
(its commands hang on macOS, as SDL found), PlayStation Bluetooth rumble, and touchpad positions for these
controllers (the click works).

Extra buttons are named this way: Share/Capture/microphone → `misc`; left back button(s) → `paddle2`/`paddle4`,
right → `paddle1`/`paddle3`. Motion is turned into Nokcandu's axes with SDL's axes for the original Steam Controller
as the bridge.

Not done: Flydigi's own protocol (it has to take the controller over from Flydigi's Space Station app, which needs
a setting in that Windows app); Flydigi controllers still work as mapped controllers.

Check on first use: Controllers.log says which driver read it ("read with its own report", "(gyro on)"), then the
buttons, stick directions and which way the gyro turns.

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
| Switch 2 Pro, GameCube (Switch 2) | 057E:2069, 2073 | `Switch2USB` (see switch-2-controllers.md) | full support by USB |
| Xbox 360 / Xbox One wired (and clones) | XInput / GIP class | `XInputUSB` (IOUSBHost) | works at all, rumble |
| Xbox 360 Wireless Receiver (and clones) | XInput class, protocol 0x81 | `XInputUSB` | up to four wireless 360 controllers, slot lights, rumble |
| GameCube adapter (Wii U / Switch) | 057E:0337 | `GameCubeAdapterHID` | four ports, four players |
| 8BitDo SF30/SN30 Pro, Pro 2/3, Ultimate 2/2C/3 (D-input) | 2DC8:… | `ReportPadsHID` | back buttons, Share, gyro, rumble |
| Google Stadia | 18D1:9400 | `ReportPadsHID` | Capture (Share), Assistant (paddle 1), rumble |
| Amazon Luna | 1949:0419, 0171:0419 (BT) | `ReportPadsHID` | microphone button (Share), Home over BT, rumble over BT |
| ZUIKI EVOTOP (PC, 2.4 GHz, Bluetooth), EVOTOP AXIS, MASCON PRO | 33DD:… | `ReportPadsHID` | gyro on the EVOTOP, rumble |
| SInput (GP2040-CE, Handheld Legend ProGCC/GC Ultimate, Firebird…) | 2E8A:10C6/10DF/10DD/10E0/10E5, 38D2:1014 | `ReportPadsHID` | paddles, Capture, touchpad click, gyro, rumble |

`ReportPadsHID` takes a controller from the generic mapping only once a report it understands arrives, so a
controller in some other mode keeps working as a mapped one.

Extra buttons are named this way: Share/Capture/microphone → `misc`; left back button(s) → `paddle2`/`paddle4`,
right → `paddle1`/`paddle3`. Motion is turned into Nokcandu's axes with SDL's axes for the original Steam Controller
as the bridge.

Not done: Flydigi's own protocol (it has to take the controller over from Flydigi's Space Station app, which needs
a setting in that Windows app); Flydigi controllers still work as mapped controllers.

Check on first use: Controllers.log says which driver read it ("read with its own report", "(gyro on)"), then the
buttons, stick directions and which way the gyro turns.

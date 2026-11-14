# Wine USB controller compatibility

Build: `SDL2_LIBRARY_DIR=/path/to/engine/Contents/Frameworks Engine/controller-hid/build.sh`.
Requires pinned Wine 11.0/Bison/llvm-mingw cache from `Engine/winemac/build.sh`,
macOS command line tools, and SDL2 headers (`SDL2_CFLAGS` can select them).
No system packages or game files are installed by this build.

This LGPL-2.1-or-later Wine modification changes the descriptor returned to the
Windows HID parser only for USB VID 057e / PID 2009 with the exact 203-byte
observed descriptor. Other devices, Bluetooth and different descriptors pass
through. The full-state 0x30 timer/battery bytes are constants; the three real
button fields and four packed 12-bit sticks have their actual offsets. Six reserved
Pro bits are constant; 18 real controls remain exposed. Raw device
reports and commands are untouched. The existing SDL route is retained.

Protocol reference: SDL's `SwitchStatePacket_t` and full report processing:
https://github.com/libsdl-org/SDL/blob/SDL2/src/joystick/hidapi/SDL_hidapi_switch.c

Hardware evidence: overlapping host/Wine idle samples showed zero actual host
button transitions versus 601 Windows transitions; the corrected module gave
zero transitions across 375 successful Windows samples. This does not certify
all physical controls, calibration, Steam Input, XInput game support, or Bluetooth.

Packaging verifies the module hash and includes source modifications/license.
Only the measured stock Wine 11.0 r1 module fingerprint is eligible; an unknown
or manually edited module is preserved. Core migration requires reliable idle
process inspection and keeps a hash-verified original before atomic replacement.
Undo in game Controls restores that original and writes a persistent opt-out;
re-enabling is explicit. No profile, registry routing, pairing or firmware changes.

## Original wired Steam Controller

The second patch admits only USB 28de:1102 usage FF00:0001 into Wine's existing
native HID path. Its separate mouse/keyboard interfaces stay excluded; receiver
1142, BLE and Deck remain outside this gate. Wine's existing native/hidden routing
policy still applies. This does not manufacture a DirectInput/XInput gamepad.
Compatible Windows Steam should use the proprietary HID interface directly;
recognition and translated game output are separate acceptance gates.

A Windows probe through the full-SDL disposable runtime opened the actual wired
vendor interface, read a feature report successfully and received 65-byte Windows
input. Native host receipt saw 64-byte status reports. No feature-write, pairing,
firmware or settings-reset commands were sent by Nokcandu's probe/profile reader.
The known stock/owned driver migration and persistent Undo restore both patches
as one module, preserving the first original. Original controller full physical
input and Steam ownership/coexistence still need user testing.

## Imitated Switch Pro Controller and DualShock 4

The fourth patch (`0004-controller-emulation.patch`) adds `controller-emulation.h` to Wine's SDL bus. The protocol itself (descriptors, input reports, the Pro's handshake and subcommands, the DualShock 4's feature reports 0x02/0x12/0xa3 and output 0x05) is Nokcandu's shared virtual-controller core, `Sources/NokcanduPadEngine/virtualpad.c` (LGPL-2.1-or-later), which `build.sh` copies in and which also drives the Mac virtual controllers. Only when Nokcandu's helper (loaded in the
environment) says a game controller should be presented as a Switch Pro Controller (`nokcandu_presented_controller`,
from the profile's `present switchpro` line) does the bus create a raw 057e:2009 HID device with the full-state Pro
descriptor, Pro reports built from the controller's events, and replies to the Pro's USB commands and subcommands
(device info, virtual SPI flash calibration, report mode, IMU, vibration). Without the helper or the line, behaviour
is unchanged. Verified inside Wine with `Tools/controller-probe/switch-pro-windows-hid.c`; see
docs/controller-capabilities.md.


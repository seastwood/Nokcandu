# Steam Controller over Bluetooth

The original (2015) Steam Controller, on firmware with Bluetooth LE support, connects to the Mac directly as
product 0x1105 or 0x1106. Added November 15, 2026; the protocol follows Valve's SDL driver (`src/joystick/hidapi/SDL_hidapi_steam.c` and `steam/controller_structs.h`).

## How it works

- Everything is HID report 3 in 20-byte segments: the report number, a header (0x80 data, 0x40 last segment,
  low three bits the segment's number) and 18 bytes of payload. `SteamControllerBLE.Assembler` joins them.
- Commands (settings, haptics, digital mappings) are the cable's commands cut to their own length and split the
  same way, sent as feature report 3 (`SteamControllerBLE.segments`). Replies are read back as feature report 3
  until whole; on macOS the report number can come twice, which the assembler skips.
- A state packet: type 4 in the low nibble of its first byte, then a bitmask (that nibble's high bits and the
  next byte) of the chunks it carries — buttons (3 bytes), triggers (2), more buttons (3), stick (4), left pad
  (4), right pad (4), accelerometer (6), gyro (6), orientation (8, unused). Only changed chunks are sent, so
  `SteamControllerBLE.Decoder` keeps the rest. Unlike the cable, the stick and left pad come separately.
- The result is the same `SteamControllerReport.State` as the cable and receiver, so profiles, pads, gyro and
  haptics work unchanged. The mode lease (pads and lizard mode off, raw motion on) is taken the same way.
- Order of preference when several are connected: cable, receiver, Bluetooth.

## Confirmed on the first connection (November 15, 2026)

Input arrives as 20-byte report-3 segments with the report number in front; settings replies join; state
packets carry only changed chunks plus empty keep-alive packets (type 4, no chunks). Reports can stall for a
moment, so Bluetooth waits 1 s before letting go of held input and doesn't take the controller over again for
it. Not yet compared with the cable: how the pads and gyro feel in use.

## Ownership and pad angles (November 17)

The shared Steam direct reader now requests exclusive HID access by default and stays active while Nokcandu
runs, even without active mappings. Controller ownership settings show blocked access and offer retry;
quitting or switching exclusive access off releases it. A shared active profile can retain its normal reader
with the option off. Native Steam coexistence and controller shutdown recovery remain hardware acceptance
items. No pairing or firmware changes are made.

Pad angle is available for every behavior, including circular scrolling and Existing mappings. Left defaults
to 0°, explicit saved angles remain, and tap/click zones rotate independently of circular scrolling.
[Implementation, tests, migration and Undo](investigations/controller-ownership-and-picture-2026-11-17.md).

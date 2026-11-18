# Advanced controller remapping

Implemented November 18, 2026 after the [sc-controller comparison](investigations/sc-controller-comparison-2026-11-18.md).
These are independent implementations using Nokcandu's existing profile model and mapping engine;
no sc-controller source or Linux input backend was incorporated.

## Setup and scope

| Feature | Where to configure | Behavior and scope |
| --- | --- | --- |
| Absolute mouse region | Controls → edit a Steam Controller profile → either pad → Pad behavior → Absolute mouse region | Map touch position to a percentage rectangle of the front window or current screen. Streams use the streamed display. Supports the original and 2026 direct Steam readers while Nokcandu is running. |
| Drawn gestures | Same pad inspector → Drawn gestures | Four commands per pad. Type cardinal paths such as `URD`, or Record a drawing and lift to finish. Bind each gesture using the ordinary input editor, including macros/layers. Recognition happens only on lift; tolerance defaults to exact. |
| Trigger arbitration | Profile editor → Triggers → Behavior | Standard two-stage, fast full pull skips soft pull, exclusive soft/full, and hair trigger. Decision time controls the first two timed behaviors; hair trigger uses a relative release distance. Applies through the shared engine, including Wine helpers and stream mappings. |
| Alternate on-screen menus | Profile editor → On-Screen Menus → Layout | Existing radial, grid, horizontal, or button-shortcut layouts. Assign an On-screen menu output to an input. Grid/horizontal use the selected stick or mouse; an absolute pad can select mouse-controlled menus without moving the game pointer. Button shortcuts stay open after releasing the opener; A/B/X/Y/LB/RB/View/Menu select, Steam/Guide cancels. Up to eight choices. |
| DSU/CemuHook raw motion | Controls → Controller Settings → Emulator motion (DSU) | Opt-in UDP server at `127.0.0.1:26760` by default, with an editable port. Configure a compatible emulator's DSU client to match. Up to four active raw motion sources. Buttons remain the emulator's ordinary controller configuration. |

Absolute regions are for cursor-based menus and inventories. Pointer-locked aiming still requires
relative mouse movement. Screen/window coordinates and negative display origins are supported;
the front-window target uses its visible bounds with a title-bar inset. This is not a game-specific
content-area detector. Holding a mapped mouse button while moving an absolute pad produces a drag.
Relative movement or a real mouse takes over the current pointer position for subsequent clicks.

Gesture recording pauses mapped direct Steam output, waits for an initial finger lift, and resumes on
completion/cancel or when its inspector disappears. Recognition uses the pad's configured rotation and
stroke length. Partial gestures are discarded on focus/profile/layer changes and disconnection. Paths
are bounded to 24 direction changes; excessive strokes are discarded rather than firing a prefix.
Ordinary pad taps are suppressed in gesture mode; explicit click/edge mappings remain available.

Hip-fire waits briefly before soft pull; a fast full pull skips soft for that pull. Exclusive mode also
prevents a slow soft pull from firing full. Hair trigger releases and presses again based on travel from
the latest peak/bottom, without requiring a return to rest. Existing soft/full thresholds remain editable.
Menu choice pulses retain their controller ownership so disconnect/focus cleanup releases them.

## Motion transport

DSU runs only while Remapping is visible and the setting is on. It binds IPv4 loopback, never a LAN
or broadcast address, and requires no virtual-controller entitlement. It exports raw acceleration in G
and gyro converted from radians to degrees per second, neutral button/stick fields, monotonic motion
timestamps and packet counters. Slot identity is stable within a server session; synthetic local MACs
identify sources without exporting hardware addresses. Stale slots can be reused.

A shared GameController motion dispatcher fans out to mapping and DSU, rather than replacing a
mapping callback. The Steam direct reader uses its own listener. Packet encoding, CRC, subscription
handling and UDP sends run on a dedicated serial queue, separate from the UI/input callbacks.
Clients/subscriptions are bounded, subscriptions expire after five seconds without renewal, and invalid
lengths, CRCs, slots and nonfinite samples are rejected. Retry and rapid enable/disable wait for old
listener cancellation before binding the replacement port. Disabling stops network/client activity.

Protocol references: [DSU specification](https://github.com/v1993/cemuhook-protocol) and
[Dolphin's DSU structs](https://github.com/dolphin-emu/dolphin/blob/master/Source/Core/InputCommon/ControllerInterface/DualShockUDPClient/DualShockUDPProto.h).
Packet acceptance and physical axis orientation in an actual emulator remain unverified.

## Compatibility, migration and Undo

Existing pad modes, trigger behavior and radial menus retain their defaults. New fields are optional;
old profiles decode without changes and default compiled engine text is unchanged. New gesture input
identifiers are appended, preserving existing numeric input identifiers. A profile that uses these new
options needs this app/helper version to execute them; earlier apps do not implement the new modes.

Wine's shared helper build hash includes the C engine and header, so existing managed helper update
paths pick up trigger/menu support. This change does not rewrite user launchers, install game updates,
or remove profiles/games/saves. Pad regions/gestures require the running app's direct Steam reader.

Undo: return pad behavior to its prior mode, choose Standard two-stage triggers and Radial menus,
and turn off DSU. Existing bindings and retained gesture/menu definitions stay available. Hiding
Remapping pauses DSU without erasing its enabled preference; showing Remapping resumes it.

## Verification

127 focused tests passed, including existing pad/mouse/routing/feature/update regressions and the new
`AdvancedRemappingTests`, `PadAdvancedTouchTests` and `DSUProtocolTests`. Coverage includes legacy
profile decoding/compilation, geometry, rotation, gesture lift/noise/cancellation, timed/fast/slow/hair
trigger pulls, alternate menu picking, quick-menu cancellation and controller-owned output cleanup.
The opt-in `NOKCANDU_DSU_E2E=1` test exercised a real loopback version query, slot query, subscription,
100-byte motion packet and stop/rebind on the same port. CRC fixtures were independently checked
with Python's `struct`/`zlib`. Grid, horizontal and button-shortcut layouts were rendered and inspected
with eight choices and wrapped labels.

The optimized app and universal Wine helper packaged successfully. Strict deep signature verification
passed, and the signed workspace build was launched. The live UI showed the new pad behavior choices,
trigger Behavior picker, all four menu layouts, and DSU off by default at port 26760. Existing profile
settings were inspected without changing them. Packaging's existing `iconutil` failure was worked around
for this local test bundle by retaining the installed app's icon and re-signing with the same identity;
no build-script/icon-source change was made. The installed application was not replaced.

Physical-controller input, actual Mac/Wine gameplay, live stream absolute positioning, and emulator
motion axes still require hands-on acceptance. Unit and transport tests do not establish those results.

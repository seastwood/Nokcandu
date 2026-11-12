# Wired Steam Controller and general headphone mappings — November 11, 2026

The user directly connected the original Steam Controller and requested native
Wine/Windows Steam access plus editable profiles. They cannot perform physical
button/pad/motion checks right now. A follow-up asks for headset control beyond
mouse, including WASD and a held radial menu. These are separate acceptance gates.

## Checklist

| Requirement | Status / evidence |
| --- | --- |
| Identify wired original | **Verified** description-only inventory: USB 28de:1102, separate mouse, keyboard and FF00:0001 vendor interfaces. This supersedes receiver-only availability for this session. |
| Expose proprietary interface to Wine | **Implemented / bounded hardware tested / packaged.** Narrow USB 1102 + FF00:1 exception in full-SDL Wine 11.0 module; keyboard/mouse, 1142 receiver, BLE, Deck and unrelated usages excluded. Windows probe opened one real vendor HID, feature read succeeded and 65-byte input arrived. Native/hidden policy remains Wine's own policy. |
| Windows Steam recognition and game output | **Pending installed UI/live acceptance.** Proprietary HID access is not a DirectInput/XInput controller and need not appear in joy.cpl. Steam's recognition, feature writes, translated game output and coexistence require separate checks. |
| Build original-controller profiles | **Implemented / software tested, physical acceptance pending.** Explicit Input controller → Steam Controller (2015 · USB). Optional saved field preserves old profiles/automatic input. Passive vendor-only reader, original layout with both pads, stick, triggers, Steam/Back/Start, rear grips and clicks. No mode reset or device commands. |
| Full report decoding | **Implemented / synthetic tests.** Version/type/length validation, signed values, every button, triggers, pads and stick multiplexing, old pad/stick click quirk, gyro/accel units, duplicate counters. Only 64-byte status packets observed live so far; they are rejected as gameplay input. |
| Disconnect/stale cleanup | **Implemented / software tested.** Freshness separate from duplicate suppression; repeated valid packets keep holds alive, status packets do not. Stale stream releases main outputs; disconnect/rebuild clears source state, preserving separate extra device slots. |
| Steam pads | **Implemented initial mapping; not full parity.** Left pad uses existing independent Touchpad settings (mouse/scroll/zones/click); right pad uses Right stick settings and centers when lifted. Right pad currently has stick/rate semantics, not independent relative-touch/trackball/haptic features. No claim of complete Steam Input parity. |
| Standalone ownership / firmware / pairing | **Pending.** Reader does not clear firmware desktop bindings, reset settings, enable sensors or seize keyboard/mouse. Existing lizard bindings or Steam Input can also act. No blind resets, mode/firmware/pairing changes. Full standalone ownership needs verified settings capture/restoration and live testing. |
| Head motion beyond mouse | **Implemented / software tested / packaged.** Mouse (legacy default), Left stick mappings, Right stick mappings. Uses existing per-layer stick controls, directions/actions/macros and radial menus. Deflection holds while the head stays turned; center releases. No new Windows gamepad promised. |
| Held radial menu / WASD | **Real C-engine tests pass** for head transform → WASD holds/releases, physical stick restoration, held radial menu selection/commit. User hardware/menu acceptance still pending. |
| Preserve defaults and Undo | **Implemented/tested.** Old profiles keep automatic macOS controllers and mouse headset output. Source changes release old main input. Driver uses existing fingerprinted idle migration, verified first original and persistent opt-out Undo. No existing profile assignments or Steam settings changed by the update. |

## Research and hardware comparisons

Primary protocol sources: Valve's SDL [packet structures](https://github.com/libsdl-org/SDL/blob/SDL2/src/joystick/hidapi/steam/controller_structs.h)
and [decoder](https://github.com/libsdl-org/SDL/blob/SDL2/src/joystick/hidapi/SDL_hidapi_steam.c),
plus upstream [Linux Steam HID driver](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-steam.c)
for interface/ownership comparison. Protocol facts informed an original Swift
implementation; no Linux GPL implementation was copied. The Wine modification
retains Wine's LGPL source/license packaging.

Passive host inventory found three interfaces: mouse 4-byte input, keyboard
8-byte input, vendor 64-byte input/output/feature. The five-second passive observer
opened nonexclusively and received five type-4 status packets. A longer observation
received 178 type-4 packets and no full input packets. User declined current
physical testing; no missing button response was invented from those observations.

The prior receiver experiment exposed four channels but used a no-SDL bus and was
not production suitable. A new candidate based on the full-SDL Pro correction
exposed **one 1102 vendor interface** while still enumerating Pro Controller,
Xbox-style output and XInput slot 0. The read-only Windows HID probe opened that
interface, reported 65-byte input/output/feature capacities (Windows includes the
zero report-number byte), successfully read a feature report and received 65 input
bytes. No feature-write or configuration requests were sent by the probe.
The production gate was narrowed to **wired 1102 only**, removing experimental
receiver inclusion and the environment override. The same read-only check passed
without that override. Windows Steam application recognition is a later gate.

The module reuses Wine's ordinary report/feature forwarding. It changes neither
packet data nor descriptors for Valve hardware. The unrelated Pro correction
remains intact: final temporary full-SDL module still reported 18 Pro buttons/four
axes, 375 successful idle samples, zero transitions and zero held buttons.

## Profile source implementation and limits

`SteamControllerReport` decodes only original USB full-state reports with version
1/type 1, 64-byte transport length, and a declared payload covering the known
44-byte structure up to the maximum 60 bytes. Status/debug/Deck/BLE/truncated
reports are not controller state. The stick/left pad multiplex flag retains the
other coordinate pair while both are used, then clears inactive state. Right pad
lift centers its virtual stick axes. All physical buttons map to existing engine
inputs, so existing toggles, holds, layers, keyboard/mouse and sequences work.

`SteamControllerUSB` listens only while an explicitly selected active profile or
editor preview needs it. It opens FF00:1 nonexclusively, never keyboard/mouse,
and never sends features/commands. It is deliberately passive: standalone full
report/sensor activation and ownership restoration remain unimplemented. The UI
states that limitation and distinguishes waiting from receipt. The editor test
has no OS output sink. Main source selection avoids mixing an original Steam
reader with the previous automatic main-controller callbacks; extra devices remain
separate. Physical input callbacks and reported sensor axes/signs need acceptance.

## Head motion mapping

`PadHeadMotionSettings.output` defaults to Mouse on old JSON. Stick options feed
the existing main-source composer and C mapping engine, rather than bypassing its
held-output ownership or inventing a virtual Windows controller. The strongest
physical/head axis wins; releasing head restores the physical axis. Buttons remain
physical, so headset output cannot activate its own held-button gate.

`PadHeadStick` centers on admission/recenter and maps wrapped attitude displacement
to normalized axes; a stationary turned head holds its direction. Range, smoothing,
dead zone and inversion are configurable. Existing hold/layer activation and
Gyro-off gating apply. Pause, removal, focus/profile change, tracking failure,
recenter and output edits neutralize old head-stick contributions. Mouse retains
its existing incremental transform. An Edit stick mappings button leads to the
same per-layer controls. This initial version shares the selected primary stick's
mapping; it does not yet provide a third independently mapped stick or arbitrary
continuous non-stick outputs.

## Validation and Undo

Twelve focused tests pass for Steam packet/source/stream behavior and headset
settings/deflection/WASD/radial menu/composition. Expanded related tests and final
installation results are recorded below. Production C gate compiles/tests allowed
wired vendor and denied keyboard/mouse/receiver/BLE/Deck/vendor cases; existing Pro
descriptor, actual-helper SDL interposition, mouse coordinate and signing checks
remain passing. Two initial test failures were incorrect fixture expectations:
using an unsupported `toggle=1` token rather than actual `keytoggle`, and assuming
opposite-direction up/down callback order. Corrected tests use real toggle syntax
and check each key's ownership sequence. No production behavior was weakened.

Undo profile source by selecting Automatic; undo headset output by selecting Mouse
or removing/disabling its source. Existing saved profile backups and Undo remain.
Restore original controller input under game Controls while the whole environment
is closed restores the hash-verified initial bus and persists its opt-out. This
undo removes both native Valve exposure and Pro correction. Managed previous-app
recovery remains available; it does not roll back desired later profile edits.
No installed game content, saves, drive aliases, credentials or system permissions
were modified, and no game/launcher was force-closed.


## Follow-up evidence and expanded field report

See [November 11 field tests](controller-field-tests-2026-11-11.md) for actual A/grip/pad receipt, missing sensor data, native Windows HIDAPI parent-metadata blocker, failed unshipped broader Wine candidate, keyboard isolation and the screenshot-backed remaining requirements. The previously listed 212-test installed baseline is now superseded by 213 passing related tests after the narrowly scoped focus-calibration change; full Steam support remains incomplete.

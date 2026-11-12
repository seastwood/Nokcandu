# Original Steam Controller: receiver, Wine and profile mapping — November 10, 2026

The user has the original wireless dongle plugged in, with the controller **off**.
The intended targets are Windows Steam through Nokcandu, other games, and full
mapping through Nokcandu profiles. Do not confuse the 2015 model with newer Valve
controllers, Steam Deck or a generic Xbox-style gamepad.

## Progress checklist

| Requirement | Status and evidence |
| --- | --- |
| Identify receiver without claiming an active controller | Implemented/tested in Core/UI. Exact USB Valve 28DE:1142 gets receiver labeling and unknown power/pairing/input status; it no longer advertises observed motion capability. Other vendors, wired 1102 and Bluetooth cases retain existing classification. Installed UI check recorded below. |
| Description-only macOS inventory | Implemented/tested tool: observed one keyboard and four vendor FF00:0001 interfaces; no device opens, report capture or feature writes. |
| Windows receiver enumeration | Probe implemented/tested using SetupAPI, no HID handles opened. Installed engine baseline exposes zero Valve HID interfaces in disposable prefix. |
| Native vendor HID bridge feasibility | Research-only patch compiled/tested in a temporary engine/prefix. Explicit opt-in exposes four Valve receiver interfaces; default off exposes zero. **Not shipped or installed into game engines.** |
| Powered-on controller / Windows Steam detection | Pending actual controller. HID inventory alone does not establish feature requests, reports or Steam Input discovery. |
| Full Nokcandu profile mapping | Pending dedicated original-controller reader/adapter, two independent trackpads, grips, stick, triggers, gyro, device lifecycle and source ownership. No phantom mappable controller added from dongle presence. |
| Steam coexistence and game coverage | Pending controller-on tests with native Mac Steam, Windows Steam and each relevant routing mode. No claim of support for every game or simultaneous ownership. |

## What the sources establish

Valve's [2015 controller documentation](https://partner.steamgames.com/doc/features/steam_controller/device/steam_controller)
describes two trackpads, rear grips, gyro and one joystick. Steam Input's mapping
capabilities do not mean every game understands the physical proprietary device.
Native-device discovery and Steam's translated game output are different gates.

The upstream [Linux Steam HID driver](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-steam.c)
and [device IDs](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-ids.h)
identify original wired 28DE:1102 and wireless 28DE:1142. The original receiver has
a keyboard interface plus four vendor-specific controller slots. Its appearance
therefore does not prove a controller is powered on or paired. The driver also
coordinates ownership with Steam to avoid duplicate input; a second reader must
not blindly reset modes or assume Steam exclusivity from missing callbacks.
These sources inform feasibility; no Linux driver code was copied into Nokcandu.

[SDL2's specialty Steam driver](https://github.com/libsdl-org/SDL/blob/SDL2/src/joystick/hidapi/SDL_hidapi_steam.c)
is default-disabled and BLE-focused. Enabling a hint globally would not establish
support for this original USB receiver. No hint, firmware, pairing or controller
mode was changed to make the inventory appear successful.

## Observations and controlled comparisons

`Tools/controller-probe/steam-inventory.swift` reads only HID properties. With the
controller off it observed:

| Receiver interfaces | Usage | Input/output/feature report sizes |
| --- | --- | --- |
| One | Generic desktop keyboard 0001:0006 | 9 / 2 / 1 |
| Four | Vendor FF00:0001 | 64 / 64 / 64 |

The Windows `wine-enumeration.c` probe now separately inventories present Valve
HID VID/PIDs without opening them, printing paths/serials, reading input or sending
feature requests. The regular installed Wine engine exposes **zero** Valve HID
interfaces. The connected Pro Controller still enumerates in its existing route,
so this is a Valve exposure limitation, not general controller enumeration loss.
The normal Wine IOHID callback rejects non-joystick/gamepad primary usages.

Research patch `Tools/controller-probe/steam-vendor-hid.patch` adds a strict,
default-off exception only for original IDs 1102/1142 and vendor usage FF00:0001.
It excludes the receiver keyboard, mice and unrelated/new Valve products.
`NOKCANDU_EXPERIMENTAL_STEAM_VENDOR_HID=1` is required. This remains an experiment,
not a supported user setting or installed runtime feature.

The candidate was compiled from the existing pinned Wine 11 source in the local
build workspace. Initial compilation lacked dlltool on PATH; adding the existing
pinned llvm-mingw tools fixed it. An initial WINEDLLPATH overlay failed to replace
the built-in driver because Wine searches its own DLL directory first. Do not
repeat that as a valid comparison. A temporary **copy of the Wine runtime only**
under /tmp, with candidate Unix/Windows winebus components, established loading of
the experimental driver without touching installed engines or copying game data.
The extracted generated source was restored after building; the patch is retained.

| Runtime / option | Present Valve HID interfaces | DirectInput/XInput observation |
| --- | --- | --- |
| Installed engine, ordinary test prefix | 0 | Existing Pro Controller still detected |
| Candidate runtime, option absent | 0 | No gamepad in this candidate configuration |
| Same candidate, explicit option 1 | 4 × 28DE:1142 | No gamepad; controller is off |

Four interfaces are four receiver slots, **not four controllers**. These tests
verify host-to-Windows HID enumeration only. The probe exit code 1 refers to zero
DirectInput/XInput controllers; the separate HID count establishes the receiver
comparison. The candidate was built from the existing configuration **without
SDL** and must not be deployed: its missing Xbox/profile path prevents treating
it as a production replacement. No running game or launcher was stopped.

## Next controller-on gates

1. First verify ordinary native Mac Steam sees the powered-on original controller
   through the dongle, without changing firmware/pairing unless a specific problem
   actually requires it. Then close only test-owned sessions normally.
2. In the temporary candidate environment, verify Windows Steam finds the original
   device through the four vendor interfaces. Check required feature reads/writes,
   report IDs/lengths, radio connect/disconnect and hotplug, with no firmware or
   pairing commands. This needs the actual awake controller; receiver inventory
   cannot substitute for it.
3. Test Steam Input mapping and gyro/trackpads/grips in a suitable game. Raw native
   identity is only useful to software supporting it; legacy games need translated
   keyboard/mouse/gamepad output. No blanket “any game” guarantee.
4. Build a dedicated profile-source adapter with exact identity/channel ownership,
   validated reports, both trackpads and correct stick/pad multiplexing. Test saved
   mappings, toggles, sequences, live edits, gyro-off hold, focus/disconnect cleanup
   and inactive-source isolation. Existing generic HID/GameController mapping does
   not expose the full original device.
5. Compare Steam-owned and Nokcandu-owned input separately before allowing hybrid
   use. Check duplicate events and mode restoration. Haptics and sensor-enable
   commands need their own validated lifecycle/Undo; no speculative resets.
6. Only after credible live tests, build a production-compatible shared Wine
   component preserving SDL and all existing controller paths, with managed update,
   backup, safe idle migration and Undo. Never install the temporary no-SDL spike.

## Production change, validation and Undo

The installed update changes only receiver status text/metadata; it does not enable
the experimental bridge. Existing profiles, games, saves, pairing, permissions and
firmware remain unchanged. 185 selected controller/profile/privacy/process/storage
tests passed; nine signing tests and the actual-helper interposition regression
passed. The updated Windows probe compiles with -Wall -Wextra -Werror. Only the
relevant IDs are labeled as receiver; no controller availability is invented.

Undo the app-only update using Nokcandu's app recovery if desired. Experimental
runtime, prefix, traces and upstream research downloads remain under /tmp and are
not packaged/committed. The description-only tools and source patch are retained
for reproducible future tests. No production engine/prefix migration is needed for
this status fix. Rollback does not need to restore profiles or game data.


## Installed status verification

The receiver-aware app update passed deep/strict signature verification and the
installed-signing continuity guard, then installed via recoverable app-only
replacement after Nokcandu quit normally. Actual installed UI under a game's
Controls now shows **Steam Controller receiver** with power/pairing/input explicitly
unconfirmed, while the Pro Controller retains its requested native route. No
profiles or permissions were changed and no game was launched for this check.
The experimental Wine components were not packaged or installed. This completes
the status-update UI gate; controller-on/Steam/profile gates remain pending.

## November 11 wired follow-up (supersedes receiver-only availability)

The original controller is now directly connected as USB 28de:1102. A new full-SDL
wired-only native exception passes actual Windows vendor HID open/feature-read/input
receipt. An explicit passive profile reader/layout and synthetic decoder tests are
implemented. This does **not** ship the old receiver experiment or claim physical
controls, Windows Steam/game support or ownership completion. The user cannot do
physical checks right now. [Current checklist/evidence/Undo](steam-wired-head-mappings-2026-11-11.md).

## November 11 wireless profile follow-up

The explicit Nokcandu source now supports the original 1142 receiver, with verified mode capture/restoration and actual input receipt. User confirmed installed wireless aiming/haptics and normal keyboard typing; installed off/wake state handling was observed. Earlier “wireless profiles pending” statements are superseded within this scope. The old no-SDL native Wine receiver experiment is still not shipped, and native Windows Steam discovery is not certified. [Current wireless notes](steam-wireless-profiles-2026-11-11.md).

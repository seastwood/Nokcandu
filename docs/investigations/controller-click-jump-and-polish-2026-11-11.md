# Controller click jump, Steam pad feel and library/editor polish — November 11, 2026 (late)

Continues the [controller handoff](controller-handoff-2026-11-11.md). Status words are deliberate: **verified** means tested here or confirmed by the user; **hypothesis** means reasoned from source and not yet confirmed on hardware.

## Click makes the cursor jump (BF1942 and other older games)

### What the user reported

- Any controller profile with gyro/stick as mouse: pressing the button for left click moved the cursor to one particular place. Worst in the virtual screen / resizable window.
- The same with a physical mouse, only with raw mouse capture on.
- After the position-free controller click (0014) was installed: a **Switch Pro profile no longer jumped; the Steam Controller profile still did** (user test, this evening).

### Three separate causes

1. **Controller click carried the Mac pointer's position** — fixed earlier today by 0014 (button-only delivery). The user's Pro result is the first acceptance of it. Scope: every game on a Nokcandu Wine 10/11 driver.
2. **The Steam Controller click was not Nokcandu's click at all (verified from the saved profile; hardware acceptance pending).** The user's Steam Controller profile maps no button to a mouse click. The click came from the controller's own built-in action (trigger = mouse click). Nokcandu's capture set both pads to NONE and lizard mode off, but the built-in *button* actions are "digital mappings", a separate table those settings don't touch. A real HID click lands at the Mac pointer, which Nokcandu's relative pad movement never moves — so the game's cursor jumped to it. The Pro has no such built-in click, which is why it behaved.
   - Fix: on verified capture, send Valve's `ID_CLEAR_DIGITAL_MAPPINGS` (0x81); on a verified restore of our own lease, send `ID_SET_DEFAULT_DIGITAL_MAPPINGS` (0x85). Both volatile and both what Valve's SDL driver does. A refused clear is logged and capture continues as before. Another owner's changed mode is still never overwritten (no 0x85 in that case).
   - Consequence the user must know: an unmapped trigger no longer clicks. Map the trigger (or pad click) to Left click in the profile.
   - This supersedes the earlier "no digital mapping commands" rule in the handoff; the user asked for all built-in Mac controls to be off while Nokcandu has the controller.
3. **Raw mouse capture with a physical mouse (source-verified; game acceptance pending).** While aiming, the Mac pointer is frozen mid-window and Wine's cursor moves by relative events, but winemac still stamped each click with the frozen pointer's position. The helper now rewrites a click made while aiming to the same position-free encoding (buttons 0–4) when the driver supports it. The older opt-in "tracked game cursor" rewrite remains only as the fallback for drivers without it.

### A fourth divergence closed in the driver (hypothesis for the reported symptom; the mechanism is verified in Wine's source)

`NtUserGetCursorPos` asks the driver for the position whenever input has been quiet for 100 ms, and winemac answers with the **Mac pointer**. After controller or raw relative input the Mac pointer is stale, so a game that polls the cursor saw it snap to the Mac pointer shortly after movement stopped. In the resizable window this is worse: while the mouse is "released" the driver deliberately does not warp the Mac pointer for the game's `SetCursorPos`, so the two never meet again.

Patch `0015-controller-cursor-stays-with-game` (Wine 10.0 and 11.0): a driver flag set by the helper whenever it posts relative movement (controller or raw) and by position-free buttons; while set, `macdrv_GetCursorPos` keeps Wine's own position. The first real absolute pointer move clears it, so a physical mouse behaves exactly as before.

### Comparisons not worth repeating

- Reading only the click path: the server and win32u handle a button without `MOUSEEVENTF_MOVE` correctly; the jump was never there after 0014.
- Assuming "the profile's left click": check the saved profile first. A click with no mapping is the device's or the system's.

### Evidence

- Saved profile JSON: Steam Controller profile has no `mouse:` output; BF1942's own profile (`pad-map`) has `rt press=mouse:left` and runs inside the game (`pad-active`).
- BF1942 wrapper checked: driver and helper both carry the 0014 selector; helper status showed all controller movement delivered as relative events, capture off.
- Wine 11.0 source read: `server/queue.c` `queue_mouse_message`, `win32u/input.c` `NtUserGetCursorPos`, `winemac.drv/mouse.c` `macdrv_GetCursorPos`, `cocoa_app.m` `setCursorPosition:`.
- Tests: `test_mouse_coordinates.py` (click encoding round-trip through the driver's decoder), `SteamControllerModeTests` (command bytes). Both drivers rebuilt with 0015.

### Fresh installs, migration, Undo

- Fresh installs bundle the new helper and drivers. Existing games take them through the existing fingerprinted, idle-only helper/driver migration; manually changed drivers are left alone and keep the old behavior.
- Undo: previous signed app through the app's rollback; the driver's original is restored by the existing driver restore while the game is closed. The controller returns to its own defaults when Nokcandu releases it or it is switched off and on.

### Still to confirm on hardware

- Steam Controller: trigger no longer clicks by itself; a mapped Left click does not jump in BF1942 (virtual screen and full screen).
- Raw capture on + physical mouse in BF1942.
- Wireless receiver: clear/restore accepted over the radio (same transfer path as the mode write).

## Steam pad feel

User: first movement of a swipe a little jittery; sometimes "resists" where the thumb is going. Saved tuning had Small movement steadiness at about 1.6 px.

- **Resistance** — verified by reading the filter: steadiness is a dead band per axis, so a change of direction must cross twice its width (about 3 px at that setting) before the pointer follows.
- **Adaptive smoothing** (new, on at 40% unless the profile says otherwise; 0 = raw): a low-pass on pad position whose cutoff rises with finger speed. A resting or slow finger is steadied; a quick movement trails by a millisecond or two. No dead band, so nothing to push through.
- **Landing ease-in**: movement ramps in over the first 30 ms of a touch (only with smoothing on), because the contact patch grows as the finger lands and its centre shifts.
- **Pad angle** (new, Valve's ±15° unless the profile says otherwise; 0 = raw axes): Valve's SDL driver turns the left pad −15° and the right +15° before use. Nokcandu read the raw axes, so a level thumb sweep came out slanted. Applied to the pad's mouse/trackball modes only; "existing mappings" (pad as stick/zones) is unchanged.
- Recommendation given to the user: set steadiness to 0 and tune Smoothing instead. Their saved steadiness was not changed.

Software-tested only (`SteamPadFeelTests`: resting noise, slow reversal, fast swipe lag, landing shift, angle, defaults without rewriting saved profiles). **Feel on the real pad is pending the user.** Undo: Smoothing 0 and Pad angle 0 restore the previous movement exactly.

## Library and editor

- Sidebar tabs: Games, **Controls** (was Profiles; the saved tab value is unchanged) and **Streams** (placeholder).
- Running items: green mark and green "Running" in the list, and a strip of running icons beside the window title on every tab (click to go to it; right-click to quit).
- **Categories**: user-made sidebar sections for anything in the library (right-click → Category). Stored in `library-order.json` (`categories`, `categoryOf`); favorites still win. Sections collapse and remember it (`collapsed`). No migration: missing keys mean none.
- Controller profile editor: below 880 pt the picture sits above the settings instead of being squeezed beside them; the pane's content is inset from its edge and scroll bar; long explanations moved to (i) buttons; header and action rows wrap or fold into a menu instead of clipping; the picture's controls scale with it so labels no longer collide.

## Follow-up, November 12: pad edge, four directions and the Steam picture (after 0.12.15)

User request: show the pad angle on the picture; an edge on each trackpad that holds another button (left pad as W A S D, Shift at the rim), with an adjustable size shown on the picture; bigger pads and a higher centre row on the Steam picture.

- **Edge**: optional per-pad `edge` (part of the radius, from the rim inward; unset or under 2% = off). While the finger is in the ring the pad's edge input (`lpedge` / `rpedge`) is held, in every pad behavior, alongside whatever the pad does there. Bound like any button, per layer.
- **Four directions**: new pad behavior. Eight-way (neighbouring directions overlap on the diagonals), with a centre dead zone and the pad angle applied. Inputs `lpup/lpdown/lpleft/lpright` and `rp…`, each bound like a button. Choosing it for the first time fills in W A S D (left) or the arrow keys (right) if nothing is set.
- **Where it runs**: the host works out which inputs are held (`PadSteamPadZones`, pure and tested) and tells the engine with `pe_pad_zone`; ten new engine inputs after the tilts. The engine's profile text format is unchanged; older helpers simply never see these inputs (Steam pads are read by the app, not inside Wine).
- **Picture**: each pad shows its axes turned by the pad angle, the edge ring at its size (lit while touched there), and for four directions the dead zone and what each way does. Steam layout: pads 104 pt (were 76), centre row raised, joystick/face buttons and grips moved to clear them.
- Existing profiles: nothing changes until an edge size or the new behavior is chosen. Undo: Edge size 0; pick another pad behavior.
- Tested in software (`SteamPadZoneTests`: eight-way and dead zone, edge in every behavior with its boundary stickiness, angle, no pointer movement in directions, engine holds and releases the bound keys, settings round-trip). **Picture layout and feel on the controller are not yet seen or confirmed.**

### Capability review (not implemented; for choosing what comes next)

Compared with Steam Input and JoyShockMapper. Present already: layers, tap/hold/double, chords, toggles, turbo, macros, sequences, radial menus, on-screen keyboard, flick stick, gyro acceleration/tightening/One Euro filter/yaw-roll mixing/auto-calibration/touch activation, tilt buttons, dual-stage triggers, device combining, sharing, per-app rules.

Gaps worth considering, most useful first:

1. Pad settings per layer (pad behavior, edge and sensitivity currently apply to all layers).
2. Pad as an analog stick for the left pad (today: directions as keys/buttons, or the old touchpad modes), and tap-to-click / double-tap on a pad.
3. Gyro: player-space / world-space turning (today: yaw/roll mix in controller space), real-world calibration (degrees per full turn), gyro as scroll.
4. Triggers as analog outputs (trigger → stick axis or mouse speed), not only soft/full presses.
5. Steam Controller over Bluetooth, more than one Steam Controller at once, and its inner-ring / click-required variants for directions.
6. Edge as analog (how far into the ring), for walk/run blends.

## Follow-up, November 12 (later): what was using the CPU, and polish before Streams

Measured on the installed app with the Steam Controller profile active (`top`, `sample`).

| State | CPU of one core |
| --- | --- |
| Before: profile editor open, Nokcandu in front | about 15–47% |
| Before: profile editor open, Nokcandu **behind another app** | about 50% |
| After: same, behind another app | about 8–20% (one reading set; not yet measured behind a running game) |

What the samples showed, in order of cost:

1. **The editor's live test ran while Nokcandu was in the background** and redrew the controller picture on every report. Each redraw resolved the whole profile once per button. Fixed: the test stops when Nokcandu is not the active app (and does not start when the window opens behind another app); bindings are resolved once per profile change; the test dot publishes at most 30 times a second.
2. **The on-screen note was rebuilt for every calibration tick** (new hosting view, measure, move, re-order), from both the runtime and the live test. Fixed: one hosting view; only its content changes while the note's shape is the same.
3. **`NSWorkspace.frontmostApplication` on every report and tick.** Fixed earlier (kept answer).
4. Pointer-capture polling asked for the front app and its windows four times a second with nothing configured. Fixed: skipped when no app is set up for capture.

Also added: an App Nap guard (`beginActivity` with `.latencyCritical`) held only while a profile is mapping a connected controller. There was none before, so macOS was free to stretch the 4 ms mapping timer behind a game.

**Not done: moving controller mapping off the main thread.** With the redraw and note costs gone the main thread is nearly idle while a game is in front, and the runtime (`DesktopPad`) shares state with profile resolution, the HUD and SwiftUI throughout. Moving it without hardware in the loop risked breaking input in a release. It remains the right long-term change; do it with a controller connected and a latency measurement before and after.

Other changes in this round: per-layer pad settings (`Layer.steamLeftTrackpad/steamRightTrackpad`, resolved by layer name through the profile stack; the runtime switches on the engine's layer change and releases held pad inputs); `PadProfiles.steamStarter()`; routing titles (`RoutingMode.title`, `ButtonRoute.title`); steadiness slider shown only when a profile still has a value; category drag and drop (`moveCategory(_:before:)`, `dropOnSection`); stale `/tmp/nokcandu-pad-*` files removed at start for dead processes only; library rescan on return to the app (nothing running, once a minute, background priority, no UI change when nothing changed).

Visual pass (screenshots of the installed app at 1203×840 and 871×732): Games, Controls, Streams, a game's Overview, and the profile editor in both layouts. Nothing clipped. Adjusted: the stacked editor gives the picture 60% of the height; the Steam face buttons sit slightly lower; the Settings toolbar button has an accessibility name. Not walked: Settings pages, installer, stores, sheets.


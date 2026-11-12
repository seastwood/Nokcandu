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

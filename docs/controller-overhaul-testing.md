# Testing the controller overhaul

November 10, 2026 development build. This is an incremental implementation, not completed game/hardware certification. See the [progress and evidence](investigations/controller-overhaul-2026-11-10.md).

## Open the updated app

1. Quit games and the existing Nokcandu normally first, so two copies do not map the controller simultaneously.
2. The user-authorized update is now installed at `/Users/seth/Applications/Nokcandu.app`. Open your usual Nokcandu. Its version remains 0.12.14; the visible **Does → Toggle** option and **Help → Controller Input Test** distinguish the updated UI. The matching staged copy remains at `/Users/seth/nokcandu/build/Nokcandu.app`; avoid running both copies.
3. This is the full app and uses your existing library/settings. It is not an isolated profile sandbox. Prefer duplicating a profile before editing it. Normal startup maintenance and managed game updates still apply.
4. Installed updates now reuse the existing signing certificate; changed-code updates retained effective Accessibility without another grant. No permissions are granted automatically. If the app reports permission unavailable, report that status rather than repeatedly resetting permissions.
5. Existing running Wine games keep their loaded helper. The new shared helper is packaged in this app; its existing managed update/restart path must complete before new routing tokens work in Wine. Do not manually replace game files or overwrite edited launchers.

## First: no game needed

In **Settings → General → Controller on the Mac**, select a duplicate of your normal profile (or create Pointer and Clicks). Enable controller profiles and Mac use. An Everywhere profile or per-app rule can override this selection; check the “Now” status before judging a test. Leave your normal profile unchanged.

Open **Help → Controller Input Test**. Click the test area, then move a mapped stick, press/release a click button, and try an ordinary mapped key. Received counts, source, key codes, movement totals and click location appear at 10 updates per second. The improved tester also shows observed held keys/mouse buttons and modifier flags. Expand Recent key and button events for ordered transitions and relative times; Copy Test Report copies the current trial locally. It observes only its own window and records no typed text. Release all controls, click the test area, then Reset Counters between trials. If focus leaves the window, held-state observation becomes incomplete; reset before the next trial. A cleared observation after focus loss does not prove the OS released an output. A count here proves receipt by this window, not by a game. Menus/system shortcuts can consume events first.

Try each separately:

- Left/right/middle/extra-button drag, both primary buttons held, then release one while the other remains held. Check down/up counts and continued drag.
- Select a controller button in the profile picture, choose **Toggle** in the **Does** behavior row, then use **Choose/Add → Key, Mouse or Controller** to select the output. Keys/mouse work on the Mac; controller buttons/triggers require the Wine output route. Press/release twice: the first press latches (the output should remain listed under Observed held keys or mouse buttons), the second releases (it should disappear). Turn profiles off while latched; verify cleanup. Avoid destructive keys while learning the controls.
- A single-button Command+Tab chord, then two buttons with a modifier and key. Test Control+Up only if Mission Control uses that shortcut in macOS. This can leave the test window; return normally. Event receipt alone does not establish system shortcut acceptance.
- Create a Macro with down, up, wait and simultaneous chord steps. New macros start with 50 ms between steps; compare zero and an explicit wait. Cancel by disabling the profile and check no delayed output continues. Old macros retain their previous timing.
- Open/edit/close the profile while moving. Valid committed changes take effect immediately; saving pauses for 250 ms and flushes on close/normal quit. Test unrelated held buttons while changing a different binding, sensitivity or Mouse/Scroll/Pad/Keys/Off output. Structural direction/flick/layer/routing or mixed edits can still rebuild and release unrelated state.
- Record a key with **Record…**; Escape cancels. Close/change the editor while recording, then verify normal app typing returns without a stray recorder. Choose Escape from the Key menu if you want it as an output.
- **Settings → General → Controller diagnostics**: enable session diagnostics, compare input receipt/emission and report age with Steam absent/present. No reports does not by itself establish exclusive ownership. Reset between comparisons. Compare local processing mean/max and tick intervals with the editor open/closed; these do not measure physical delivery or game response. Motion callbacks and nonzero rotation samples are separate counts. Disable diagnostics after comparing.

## Capture and critical game checks

In **Settings → General → Controller pointer capture**, Add an Application and explicitly select the game wrapper or external streaming client. Capture is independent of its controller profile. Disabled is the default. Start with Manual; **Control–Option–C** toggles it and **Control–Option–Escape** releases it regardless of the profile. Confirm the capture status names the foreground application.

This implements fixed-anchor, process-directed **mapped controller mouse** events. It does not seize a physical mouse, hide/disassociate the cursor, or guarantee acceptance by every target. Native/streaming clients that reject injected events may not work; protected targets are not bypassed. Do not infer physical-mouse capture from the setting name.

| Test | Compare and record |
| --- | --- |
| Overwatch delayed movement | Same scene/profile, capture Disabled then Manual; gyro and stick separately, before and after a shot. Does aim respond continuously without shooting? Record receipt/emission counts versus visible response. |
| Battlefield 1942 click jump | Stationary aiming then click; continuous turning then click. Does the aim jump at down/up? Compare capture modes without changing other settings. |
| Turning/edges/Dock/menu bar | Long pitch/yaw, windowed then fullscreen, each display. Does turning stop, the Dock/menu appear, or a click reach another app? Keep a physical keyboard available for emergency release. |
| Focus/lifecycle | While holding a key/click, switch apps, change Space, disconnect, sleep/wake, quit normally. Verify release. Manual mode must be toggled again after activation is lost; Automatic is foreground scoped. Never revoke permissions mid-game without a way to exit. |
| External streaming client | Select the actual client; repeat movement/click/focus checks. Exact generated Nokcandu GameApp helpers inherit an explicitly selected wrapper rule; unrelated third-party helpers must be selected directly. |

These game-specific issues remain **unverified**. Please record what failed, target app, window/fullscreen, controller connection and capture mode. Avoid raw account/session logs.

## Routing and multiple inputs

In a duplicate profile, the Routing picker provides Existing behavior, Native input values, Hybrid primary inputs, Mapped primary inputs only, legacy button-only presets, and Selective inputs. Selective exposes native/mapped/both/disabled routes for buttons, stick groups, triggers, gyro, touch and tilt.

Use a target input monitor/game to compare physical and mapped output independently. Native input values means input-value routing within the existing Wine driver, not restoration of an original Windows device identity. Native macOS physical-device suppression and native Wine sensor passthrough are unavailable. Native touch event visibility is specific to the intercepted Wine SDL path. Logical Xbox-style output is not a true virtual controller.

For additional device slots, hold actions on two sources, disconnect one, and verify the other source remains active. Slot replacement must clear the previous source's latched actions. Main GameController sources still compose one logical group; persistent per-physical-controller routing is incomplete. No new original Steam Controller protocol support is claimed. The observed Pro Controller session received motion callbacks alongside Steam, but nonzero motion-to-output and target-game behavior still need testing.

## Preferences and experimental inputs

- General → Startup: verify Open Nokcandu at Login placement and persistence; changing it is your choice.
- Dismiss Setup Checklist once, reopen normally, verify it stays dismissed even without Wine setup; reopen from the menu when wanted.
- Disable automatic gyro-calibration notifications; calibration must continue silently. Manually calibrate and verify visible feedback even when general layer/gyro notes are off.
- Automatic calibration (November 13, 2026): hold the controller still for 5 s and put it down for 5 s; drift must be corrected each time with nothing on screen unless the correction was 1 degree/s or more. Aim slowly and steadily; the calibration must not change.
- In a duplicate profile, choose **Add Device → AirPods / Headphones (experimental)**, then select its source chip. Sensitivity, response, dead zone and inversion are saved with that profile. It runs only when this opted-in profile is active; old profiles stay opted out. macOS may request Motion permission. Test recenter, controller composition, **Gyro off while held**, switching to a profile without headphones, and uninterrupted audio. Remove/disable the source to stop it. General settings now show status and directions rather than global tuning. Hardware/audio support remains unverified.

## Undo

Disable/remove capture rules and experimental motion; turn off controller profiles to stop mapped output. Quit the development copy normally, then reopen the installed app by its full path. The user subsequently authorized installation: the usual app has now been updated, with a verified recovery app and restore command under `~/Library/Application Support/Nokcandu/App Versions/`. Restore that app-only recovery copy if needed; do not overwrite newer profile data when rolling back.

A first new-feature save preserves original shared bytes as `~/Library/Application Support/Nokcandu/controller-profiles.json.pre-controller-v2`, and own-profile bytes as `<Game>.app/Contents/SharedSupport/nokcandu/pad-own.json.pre-controller-v2`. Existing backups are not overwritten. These are local recovery files, not created merely by launching the editor. Export/duplicate profiles before tests; a rollback to an old app may not understand new features. Restore backups only with both copies quit, preserving any later wanted edits first. No game content/save migration is required.

If a save reports that profile settings were saved but some controller maps could not update, the saved profile is retained, successful maps are updated, and the bad map path is preserved. Repair that path deliberately and retry. Do not delete an unexpected folder/link just to dismiss the error.


## Short order for tonight

1. In a duplicated profile, test ordinary keys/clicks, then one key toggle and one mouse toggle in Help → Controller Input Test. Check observed held outputs after the physical button is released; press again to release the output. Copy the report if the result is wrong.
2. Test a short sequence with explicit waits. Expand Recent key and button events and check the order/times; these are window receipt times, not device latency.
3. In a Wine game set "Controllers in this game" (or "in Steam games") → As itself, close the environment normally, then Test Controllers. Pro Controller is now verified under DirectInput. Native mode may correctly have no XInput slot; games requiring XInput should be tested separately using As an Xbox controller.
4. Test Overwatch aim before/after firing and BF1942 aim/click jumps, then capture/edges/focus. Keep the profile and scene constant between comparisons. These remain actual game acceptance gates.
5. Test headset motion only with compatible headphones and when ready for macOS’s Motion permission prompt. Do not judge hardware support from configuration UI alone.

For a failed game test, note game, controller/connection, route, profile, capture mode, fullscreen/windowed and the exact action/result. Do not send account/session logs. An input-test report verifies only its own window; it is useful alongside the game observation, not as proof the game received the same events.


## Original Steam Controller when you can turn it on

The 2015 wireless dongle now appears as **Steam Controller receiver**. That label
means the USB receiver is present, not that the controller is awake or paired.
Leave pairing and firmware alone for the first test. When ready, turn on the
controller and we can compare native Mac Steam detection, Windows Steam through
Nokcandu, then profile mapping. The research-only bridge has exposed the four
receiver channels to Windows in an isolated test, but is **not installed** in your
game environments. Do not expect the ordinary Windows panel to prove this future
bridge works yet. Full trackpad/grip/gyro mapping remains pending live tests; see
[the exact evidence and next steps](investigations/steam-controller-2015-2026-11-10.md).


## Headphone fine-aim activation and current field-test retest

Select **Profiles → your profile → AirPods / Headphones → Activate head motion**.
Choose **While a controller button is held** and a button (for example L), or
**Only in a selected layer** and your fine-aim layer. Create/use a normal Hold Layer
or Toggle Layer binding to enter it. The layer option stays inactive until a layer
is chosen. Controller gyro continues; explicit Gyro-off holds pause both. Activation
does not consume the chosen button's ordinary mapping: set that mapping to Nothing
if you want only headphone activation. Existing sources retain Always automatically.

Retest Overwatch virtual-screen gyro/stick aim and click alignment after closing
the full game/launcher normally so the updated Wine driver/helper can load. For
BF1942's edge stop, compare Disabled capture with explicit Manual capture on the
actual game wrapper; Control–Option–C activates and Control–Option–Escape releases.
The new Wine capture route avoids the process-event path the raw helper can swallow.
These fixes are automated/build tested, not yet game-certified.

The Pro Controller rapid-input issue was reproduced in generic Windows decoding.
The correction now passes bounded native idle receipt and automated migration/
Undo tests. The updated app is installed. Fully close Steam normally, then
open Test Controllers to apply the known-engine correction at the next start.
Controls shows its status and Restore original controller input; restoration
stays off until Enable input correction is chosen. Verify no rapid idle buttons,
then every individual button/stick in the Windows panel before a game trial.
This does not create XInput from a native device or certify Steam Input mappings. Keep native-vs-Xbox and Steam Input
comparisons separate. Steam showing correct raw inputs does not prove an XInput
pad reaches Trackmania. The user-confirmed mystery gyro was Steam Input output,
not something the Nokcandu master switch controls. No Steam settings were changed.

The final installed native Windows idle check passed with 18 buttons/four axes,
zero held buttons and zero transitions over 375 successful samples. Your next test
should press each actual button and move each stick, then compare Trackmania's
As itself + intended per-game Steam Input setup against As an Xbox controller
with unintended duplicate mapping disabled. Record which route responds; discovery
alone does not prove the game receives usable output. BF1942's controller pointer
capture is separate from its existing physical raw-capture compatibility setting;
leave physical raw capture off for that comparison.

## Original Steam Controller USB and headset stick outputs

In Profiles choose your profile → **Controller input → Steam Controller, read directly (trackpads, haptics)**.
Both pads, one stick, grips and triggers have an original-controller layout. Left
trackpad opens Touchpad settings; right pad opens Right stick settings and centers
on lift. Use its experimental test status to distinguish USB connection from full
input receipt. The reader is passive: original desktop bindings or Steam Input may
also act; standalone mode ownership/sensor activation are not completed. Physical
controls remain to be tested when convenient. As itself exposes proprietary HID to
compatible Windows Steam, so check Steam's Controller settings; joy.cpl is not a
complete discovery test for this device. Keep gameplay translation a separate test.

For AirPods choose **Head motion controls → Left stick mappings** (for WASD/custom
movement) or **Right stick mappings**. Use **Edit … stick mappings** to configure
that stick's existing modes/directions. For a radial menu, set its Pick with to the
same stick, bind a controller button to that menu, and optionally use that same
button as the headset's while-held activation. Hold, turn your head, then release
to commit the menu item. Head motion shares that stick's mapping with physical
input; the stronger deflection wins. Full deflection angle controls head range.
Return to Mouse to restore previous behavior. Hardware/menu acceptance is pending.

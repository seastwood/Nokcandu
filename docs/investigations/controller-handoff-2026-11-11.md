# Nokcandu controller handoff — November 11, 2026

## Resume here

The final requested increment — independent **trackpad mouse / trackball mouse behavior for either original Steam Controller pad** — is implemented, tested and installed. The right pad is configured for trackball aiming in the Steam Controller test profile. The user confirmed the baseline trackball behavior, then reported bad release-direction flings. The correction, X/Y tuning, touch gyro, movement haptics, pulse controls and gyro-notification switch are now installed; hardware confirmations and limits are below. Do not resume the entire overhaul automatically from this handoff: the user limited the session to this increment plus documenting the handoff.

The larger project is not complete. The user's eight-page `11-11-26 Top Priority Prompts.pdf` superseded the original general ordering for this session. Screenshots and text were examined. Current checklist/evidence: [November 11 priorities](controller-priorities-2026-11-11.md). Main history: [controller overhaul](controller-overhaul-2026-11-10.md).

## Completed and verified earlier today

- Corrected the custom Wine 11 controller bus's wrong SDL runtime dependency. The engine contains old `libSDL2.dylib` (2.0.20) and stock versioned `libSDL2-2.0.0.dylib` (2.32.64 compatibility runtime). The previous custom build loaded the old one. Build now requires/verifies the stock versioned dependency and refuses fallback. Isolated default conversion exposes one Pro, Xbox and wired Steam gamepad, with three XInput slots. Native mode exposes Pro in DirectInput and Xbox in XInput; Valve vendor HID is separate.
- Installed corrected controller bus through the existing fingerprinted, idle-only migration. Actual shared Steam native-mode receipt captured physical Xbox/Pro button and stick input: 30,858 successful samples each, zero read errors. This is Windows input receipt, not Trackmania gameplay acceptance or certification of all mappings.
- Added shared Wine 10/11 button-only controller click delivery. Prior relative motion could advance Wine's cursor while a CGEvent click supplied the Mac pointer's stale absolute position. The optional driver selector queues a reserved controller encoding; the real handler emits button flags without movement. Ordinary mouse events keep their existing behavior. Capability gating preserves old/stock drivers. Socket releases stay with their original process and Wine window. Both drivers build; real-handler tests cover five buttons down/up, invalid encodings and unchanged physical mouse flags. BF1942/BF2/Overwatch acceptance is pending. This path requires Nokcandu's matching Wine driver; environments using stock drivers retain the fallback.
- Added **Import Layer → profile → layer** in the profile editor. It copies explicit settings, clones referenced macro/menu dependencies recursively with fresh IDs, renames collisions/self references, and rejects missing dependencies/capacity overflow atomically. Existing base behavior remains. UI menu/sources verified. Three import tests pass. Inherited base settings, profile-wide pad/source choices and sequences are intentionally outside this layer copy.

## Steam Controller takeover and doubled keyboard input

A read-only selected-settings query on actual wired 28de:1102 measured left pad mode 3, right pad mode 0, lizard mode 1, IMU mode 0, packet version 2. Firmware desktop keyboard/mouse was active; motion reports were disabled.

A bounded two-second hardware test changed only volatile pad/lizard/IMU settings, verified read-back, restored the exact original values and verified restoration. No digital mapping clear/reset, factory/default, pairing or firmware commands were used.

The USB reader now uses a reversible mode lease before accepting input:

- Pads set to NONE, lizard desktop controls OFF, raw gyro/acceleration bits enabled; other IMU bits and packet version retained.
- Acquire/read-back failure pauses the reader rather than knowingly mapping alongside firmware desktop input.
- On last listener/normal termination, restore only if the same connection still has the applied mode. Another owner's changed settings are preserved.
- Local `steam-controller-mode-lease.json` recovery receipt supports an interrupted process on the same registry connection; no serial or account data. Do not commit receipts. A different registry connection is deliberately not restored from an old receipt.
- Concurrent Steam/digital mapping ownership and replug/recovery behavior still need broader hardware testing. This is not a global USB seizure or a native Windows Steam driver replacement.

Keyboard duplication was reproduced by the user while the old Steam reader/test page was active, persisted when mapping profiles were switched off, and stopped when Nokcandu closed. Reopening Nokcandu on Controller on the Mac with profiles off gave normal typing. After installing takeover, the user confirmed **normal typing with the Steam Controller profile/test reader active**. Installed active mode read-back was 7/7/0/24/2; releasing mapping and leaving the test page restored 3/0/1/0/2 exactly. Treat this as a successful controlled retest, not proof that every possible duplicate-input conflict is solved.

Sources: [Valve/SDL constants](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/steam/controller_constants.h), [feature structures](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/steam/controller_structs.h), [Steam driver](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_steam.c).

## Trackpad/trackball increment

Implemented source:

- Optional `steamLeftTrackpad` and `steamRightTrackpad` profile settings, independent per side. Nil retains the old left-touchpad/right-stick behavior. New settings round-trip without opting old profiles in.
- **Existing mappings**, **Trackpad mouse**, **Trackball mouse**. Sensitivity, inversion and momentum half-life are adjustable. This increment's behavior choices apply to all layers.
- Relative movement uses finger displacement, not held pad position. Finger landing does not jump. Trackball coasts after a recent flick/lift with time-based exponential decay. Touching again stops it; a resting finger does not launch stale momentum.
- Finger-up status reports do not reset the momentum clock or cancel the coast. The first regression test caught that bug; it was corrected before packaging.
- Right-pad mouse modes zero its virtual right-stick axes before engine mapping, retaining the physical joystick and triggers. Native/disabled control routing suppresses custom mouse conversion.
- Preview and live desktop/Wine output share the pure motion processor. Profile/source/focus changes, stale input and reader teardown cancel motion. Output follows the existing mouse/capture/menu delivery path.

Six focused tests cover relative behavior versus joystick velocity, lift/coast/touch stop, timer-cadence equivalence and finger-up reports, rest/gap/invalid/reset cancellation, right-stick suppression with preserved physical controls, independent settings/JSON/legacy defaults/routing.

Final packaging/UI/physical acceptance status is recorded below. Do not claim game aiming feel, full Steam gyro correctness or every axis mapping from processor tests alone.

## Where the code lives

| Area | Files |
| --- | --- |
| SDL dependency/build regression | `Engine/controller-hid/build.sh`, `sdl-runtime.sh`, `Tests/BuildScripts/test_controller_sdl_runtime.py` |
| Safe controller module migration | `Sources/NokcanduCore/ControllerHIDFix.swift` |
| Raw Steam decoding / lifecycle | `Sources/NokcanduCore/SteamControllerReport.swift`, `Sources/Nokcandu/SteamControllerUSB.swift` |
| Reversible volatile mode codec | `Sources/NokcanduCore/SteamControllerMode.swift`, `SteamControllerModeTests.swift` |
| Pad motion / settings / routing | `Sources/NokcanduCore/PadSteamTrackpad.swift`, `PadProfiles.swift`, `PadSteamTrackpadTests.swift` |
| Runtime / preview / UI | `Sources/Nokcandu/DesktopPad.swift`, `ControllerPicture.swift`, `SteamTrackpadInspector.swift`, `ControllerProfileEditor.swift`, `ControllerProfileExtras.swift` |
| Layer import | `Sources/NokcanduCore/PadLayerImport.swift`, `PadLayerImportTests.swift` |
| Shared positionless clicks | Wine 10/11 `0014-controller-button-without-cursor-warp.patch`, `Engine/winemac/controller-mouse-button.h`, `Resources/rawmouse/padmap.m`, `rawmouse.m`, `PadMouseSocketRoute.swift` |
| Read-only/bounded diagnostics | `Tools/controller-probe/` (see README; default settings query is read-only, `--test-mode` explicitly changes/restores volatile mode) |

## Remaining work in priority order

1. Accept Pro/Xbox input in **Trackmania itself**. User disabled Steam Input for Pro earlier because Steam's gyro-to-mouse was unwanted. Native Pro detection does not imply XInput-game support without translation. Preserve explicit routing; do not silently relabel conversion as original passthrough.
2. Accept both trackpad behaviors physically; tune right-pad aiming/decay. Add left-pad **WASD/joystick movement with adjustable edge sprint**. Touch-controlled gyro and right-pad haptics are implemented and user-confirmed; new pulse tuning still needs subjective acceptance. Confirm Steam gyro axes and units with deliberate rotations; enabled reports are not yet a direction/aim certificate. Receiver/wireless support, true original Windows Steam discovery, generic action rumble, Steam ownership/coexistence and reconnection remain partial/pending.
3. Layer import implemented; expand only where actual usage requires inherited snapshots, automatic dependent-layer import or additional device resolution. Current explicit-copy errors are safe and intentional.
4. Investigate Control+arrows invoking Mission Control/Spaces. Do not claim synthetic key events trigger system shortcuts without a real test.
5. Test new shared click delivery in BF1942/BF2 virtual screen, physical mouse unchanged; retest Overwatch. Check raw capture on/off, menus/gameplay and down/up after focus change.
6. Same-profile focus retains calibrated engine bias (automated). Different/no-profile transitions and physical drift/stall acceptance remain pending.
7. Battle.net display controls and Overwatch full-screen scaled click offset remain pending. Fix shared generation/presentation paths, not a per-game workaround for a general coordinate bug.

BF2 deployment menu: user confirmed Wake Island and Dalian Plant improved; final file-based transport and central save-preservation fixes are in source. Severe performance remains deferred at user's request (~1 FPS Wake online; 10–20 Dalian single-player). Keep normal BF2Hub→BF2 launch path. [BF2 notes](bf2-deployment-menu-2026-11-11.md).

## Validation and installation discipline

- Before trackball: 597 Swift tests passed, 19 optional integration skips, no failures; privacy tests passed. Fifteen build-script tests passed on the prior mouse/layer increment. Six additional trackpad tests passed; final full-suite/install results follow below.
- Stable app signing identity preserved; do not use a signing-change override or reset Accessibility for ordinary builds. Signature verification needs normal Mac trust access; restricted verification previously falsely reported trust/identity failure.
- Install via the app's reversible `nokcandu-settings --install-app` path after quitting Nokcandu. Controller/Wine driver changes apply only to recognized owned modules while their environment is closed. A new build signature can make the compatibility row show pending until the next idle start.
- Many preexisting/unrelated workspace changes remain. Do not blanket revert/stage/commit them. No agents were spawned. Do not commit runtime/game binaries, raw logs, recovery receipts, credentials or machine backups.
- Update `docs/engineering-learnings.md`, relevant compatibility notes and the priority checklist with confirmed fixes. Keep unsuccessful comparisons and limits explicit.

Undo: choose **Existing mappings** independently on either pad; turn profiles off and leave the Steam test page to release the last reader and its mode lease; use editor Undo for layer import. Prior signed app and original driver backups remain recoverable through existing install/compatibility restoration. Do not restore a driver while its Windows environment is running.

## Final packaging checkpoint and competing copies

During the final update, process inspection found a development `build/Nokcandu.app` process remaining after the installed copy closed. UI app lookup can select a running copy sharing the same bundle ID; selecting an app by name/path is not sufficient evidence of the active executable. Both old copies were closed before the final installation. Always check the running executable path and new UI controls after installing.

Updated readers now hold a per-user kernel advisory lock across mode acquisition, receipt and restoration. A competing updated Nokcandu copy fails closed with an explicit reader-unavailable message. Lock descriptors are close-on-exec so launched games cannot retain ownership after Nokcandu exits. Tests verify contention/release and rejection of linked lock paths. This protects updated copies; old binaries predating this guard can still compete and should stay closed.

The final trackball integration also cancels residual momentum when the on-screen keyboard opens. Left-pad WASD/edge sprint was not implemented in this increment. Source changes after this checkpoint require normal tests and rebuilding before installation; do not assume earlier 603-test packaging includes the ownership guard.

## Initial trackball installation checkpoint (superseded by follow-ups below)

- Final source passed **605 Swift tests, zero failures, 19 optional integration skips**. Privacy tests passed; the old four failures are not present under normal process/trust access. Fifteen build-script checks passed for the driver/helper changes; no subsequent driver/helper source changes invalidate that run. `git diff --check` passed.
- Final app built, passed strict/deep signature and signing-continuity verification, and was installed through the recoverable app installer. Verified the only running Nokcandu executable is `/Users/seth/Applications/Nokcandu.app/Contents/MacOS/Nokcandu` (not the development copy).
- Installed UI: right pad → **Pad behavior: Trackball mouse**, sensitivity **1500**, momentum half-life **0.16 s**, inversion off. Controller diagram/accessibility label says **Right trackpad: Trackball**. The saved Steam Controller profile JSON independently confirms `steamRightTrackpad.mode=trackball`; `steamLeftTrackpad` remains nil, preserving the existing left touchpad configuration.
- Left pad's independent chooser was inspected and offers Existing touchpad settings, Trackpad mouse and Trackball mouse. No left-pad behavior change was made. Returning to right-pad settings preserved Trackball mouse.
- Global profiles and the existing Everywhere: Steam Controller selection are active, as the user had enabled during testing. The app was left on right-pad trackball tuning controls with the wired source receiving input and its firmware desktop controls captured.
- User was invited to test swipe/lift coast, touch-to-stop and stationary contact. No physical trackball/aiming acceptance has been received at this checkpoint. Automated motion behavior and saved/installed UI are verified; do not claim in-game aiming feel is certified.
- The old left-touchpad footer was subsequently corrected to refer to independent right-pad behavior settings.

Quick retest: keep other Nokcandu copies closed; swipe the right pad, lift, then touch again. Holding a finger still should not keep aiming. Compare Trackpad mouse to remove momentum, or Joystick settings to restore prior behavior. Choose the left pad to configure its behavior separately. Tune sensitivity for distance and half-life for coast duration. Retest MacBook typing and native/virtual-screen games independently.

Do not attribute all historical doubled physical-keyboard input solely to firmware desktop mode: another running development copy was also discovered. The confirmed results are the user's normal-typing retest after takeover, exact mode acquire/release read-back, and final single installed-process verification with the new updated-copy reader lock.

## Follow-up: axis sensitivity, touch gyro, movement haptics and release direction

The user confirmed the baseline trackball mode works, requested independent X/Y sensitivity, touch-to-activate gyro and subtle movement feedback, then reported occasional upward or reversed fling on finger lift. These observations supersede the earlier broad baseline acceptance; the user subsequently confirmed “Fling direction is fixed.” This is a desktop/profile test, not certification across all games.

### Measured release anomaly and correction

A passive, nonexclusive three-minute coordinate observer (`Tools/controller-probe/steam-pad-release.swift`) captured twenty deliberate swipe/lift tails. On one left swipe, valid-contact X progressed to -30490, then reversed to -27908/-24976 while Y abruptly changed from -1848 to -12756/-20908 before the touch bit cleared. The old coast used the final sample's velocity. The zero coordinates in the actual touch-up packet were already ignored; that was not the cause.

Flick velocity now uses component medians from a short recent history (up to 80 ms, excluding the last 18 ms when enough data exists), rather than the final derivative. A fixture derived from the measured tail verifies left/right flick direction and prevents the vertical spike dominating the coast. Normal finger movement remains immediate: no new delayed input buffer or forced horizontal axis lock. Residual physical-contact noise can still move the pointer before lift; this correction targets sustained fling direction. Very short gestures have less history and intentionally fall back to available samples.

### New controls

- Optional per-pad `sensitivityX` / `sensitivityY`, falling back to the old shared sensitivity when absent. Existing profile JSON remains valid and old movement stays unchanged until edited.
- Optional **Activate gyro while touching** on either pad. When either option is selected, controller gyro is active only while at least one selected pad is touched. The engine's explicit gyro-off hold and native/disabled gyro route still win. Touch-off immediately centers gyro-stick output without releasing unrelated keys. Calibration bias is retained; transition clocks/filter history reset to avoid a burst. This gates controller gyro, not the independent AirPods activation settings. Enabling the option offers a mouse gyro mapping if gyro output was off; gyro tuning remains under Gyro settings.
- Optional **Movement haptics**, strength and **Test haptics** for either pad's mouse/trackball modes. Uses original-controller transient 0x8f haptic bursts; three bounded pulses (up to 10.5 ms with the later spacing control), shared rate limit of at most forty requests/second/pad across preview/live outputs. Stationary contact sends none; coasting can send pulses. Output requires the verified mode lease/reader ownership and stops after an output error. No persistent haptic setting, mapping or firmware reset.

Actual hardware accepted a bounded right-pad haptic command (`IOReturn=0`, about 0.45 ms call time). The user subsequently confirmed feedback was felt on the right pad. They found its texture odd, motivating the pulse controls below; matching Valve’s exact feel is not claimed. Protocol references: [Valve feature message layout](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/steam/controller_structs.h), [command constants](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/steam/controller_constants.h), [Steamworks haptic semantics](https://partner.steamgames.com/doc/api/isteaminput).

Six new tests cover axis/old-JSON compatibility, the measured bidirectional release regression, actual-engine touch gyro/off-hold/native routing, immediate stick centering with unrelated holds retained, and bounded haptic encoding/rate limits. Twelve focused pad tests passed. The enhancement build passed 611 total Swift tests and fifteen build-script checks, was signed and installed. The user confirmed gyro moved only while touching and the corrected fling direction remained stable. Current changes are incremental; no unrelated overhaul stages were started.


## Final increment: pulse tuning and independent gyro notifications

**Implemented, tested and installed:** either pad’s mouse/trackball inspector now exposes Haptic strength, Pulse rate (5–40 bursts/second), Pulse spacing (0.1–3 ms within a burst), and Test haptics when Movement haptics is on. Rate adjusts repetition during movement; spacing adjusts the texture of each three-pulse burst independently of strength. The test button sends one burst, so move the pad to judge repeat rate. Preview/runtime share the per-pad limiter; stationary contact produces no movement feedback. Bursts remain finite (maximum 10.5 ms), with ownership/error guards unchanged. Physical right-pad output was confirmed earlier; subjective acceptance of the new tuning remains pending.

Optional `hapticRate` / `hapticSpacingMS` fields preserve existing profiles: absent values retain 40 bursts/s and 1 ms spacing. No game/runtime migration or controller firmware change is needed. Undo: restore those defaults or switch Movement haptics off.

**Gyro on/off notifications** is a separate global preference, available beside touch activation on either pad and under Controller on the Mac. It suppresses only gyro-state notes, including hiding an already-visible gyro note when disabled. The existing master HUD switch still wins. Layer and automatic calibration preferences are preserved. Legacy installs default to gyro notes enabled; no profile rewrite is required. Undo: switch it back on.

Final validation: **615 Swift tests, zero failures, 19 optional integration skips**; privacy tests pass. Four new pulse/notification tests cover packet bounds, independent strength/spacing, per-pad cadence, JSON compatibility and preservation of the legacy master/calibration settings. Fifteen build-script tests passed after the preceding engine changes; no later driver/helper changes invalidate that run. Strict/deep signature and signing-continuity verification passed, followed by recoverable installation.

Installed UI and screenshot verify all three haptic sliders and both gyro switches. Gyro notifications are now **off**, while layer/master and automatic calibration notifications remain **on**. Right pad remains Trackball mouse, X/Y fallback sensitivity **647.3123**, half-life **0.16 s**, inversion off and touch gyro on. Movement haptics was temporarily enabled to inspect the sliders and returned to its prior **off** state; enable it to tune the new pulse controls. Left pad retains existing touchpad mappings. Only `/Users/seth/Applications/Nokcandu.app/Contents/MacOS/Nokcandu` was running at final verification.

Additional source map: `Sources/NokcanduCore/SteamControllerHaptics.swift`, `PadNotificationPreferences.swift`, `Sources/Nokcandu/PadHUD.swift`, `SettingsView.swift`, and `Tests/NokcanduCoreTests/SteamPadEnhancementTests.swift` / `PadPulseNotificationTests.swift`. No broader remaining overhaul stage was started.


## Movement-linked haptics and Steam diagram follow-up

User requested pulse cadence to follow trackpad cursor speed and corrected placement of Steam Controller controls. **Implemented / tested / installed:** new per-pad **Match cursor movement** switch is on by default for enabled movement haptics; explicit false restores the prior fixed rhythm. Optional `hapticFollowsMovement` preserves decoding of existing profiles, haptic enablement, strength, rate and spacing. No game content, routing, firmware or permission migration is involved.

The shared haptic processor integrates the magnitude of emitted pad cursor deltas and requests a burst per 16 units of travel, bounded by the existing chosen maximum pulse rate. Slow movement pulses less often, fast movement hits the cap, and trackball coast slows the feedback. This follows Nokcandu’s pad output, not an independent measurement of macOS acceleration or the game camera. It excludes gyro and physical mouse movement. Distance accumulates separately for each pad; long idle gaps/clock rollback discard partial travel, reset clears history, and a cap of one pending burst avoids delayed buzzing after a fast flick. Zero movement sends no burst. Test haptics retains its one-burst behavior. Preview skips its feedback contribution while the desktop Steam source is active, preventing the same cursor travel being counted twice; the preview still works with profiles off.

Steam-only diagram changes put Back/Steam/Start on a center row, move both pads, joystick and compact ABXY cluster, spell out Steam and label the rear grips **Rear L / Rear R**. Mapped ABXY captions are placed outward so they do not displace or cover neighboring buttons. Mapping IDs and hit actions remain unchanged, and other controller families retain their positions. Reference: [Valve’s original quick-start guide](https://steamcdn-a.akamaihd.net/steam/apps/353370/manuals/SteamController_QuickStartGuide2016.pdf). This remains a schematic, with rear controls labeled on the front overview rather than a second rear drawing.

Validation: **616 Swift tests, zero failures, 19 optional integration skips**, including privacy checks. New movement tests verify slow/fast pulse counts, maximum rate, axis-independent travel, per-pad isolation, idle/reset behavior and zero motion; JSON round-trip includes the new option. Final focused tests and app compilation pass after preview/diagram refinements. Visual verification used the installed app: center row, compact ABXY/outward Menu caption, rear labels and Match cursor movement are visible. Signature/deep verification and signing continuity pass; installed through the recoverable installer. No driver/helper change since the fifteen passing build-script tests.

Final saved UI: right Trackball mouse, X/Y fallback 647.3123, half-life 0.16 s, touch gyro on, gyro notifications off. The user had enabled Movement haptics and adjusted it to strength 35%, maximum rate about 28/s and spacing about 2.3 ms before this install; those settings were retained, with Match cursor movement on. Earlier handoff state with haptics off is superseded. Physical feel of the new speed-linked cadence remains **pending user acceptance**; prior right-pad haptic output, fling direction and touch-only gyro remain user-confirmed.

Undo: turn Match cursor movement off for fixed cadence, or turn Movement haptics off. Layout does not change bindings or require profile edits. Broader remaining overhaul stages were not resumed.

## Receiver source added after the initial handoff

User expanded scope to original wireless dongle support. Existing `steamUSB` source now accepts cable or original 1142 receiver with one active controller, verified volatile capture, radio disconnect release, bounded retry and asynchronous wireless haptics. Profiles/trackball/touch-gyro tuning are reused. Three-minute hardware receipt and exact mode restore passed; user confirmed installed wireless aiming, haptics and normal keyboard typing. Installed off/wake states release and resume input. Suite: 620 tests, zero failures/19 optional skips. Native Windows Steam wireless discovery, BLE and broader replug/coexistence remain pending. The initial memory-only wireless lease was incomplete across off/wake and is superseded by remote-identity recovery; see the latest wireless notes. [Full wireless evidence and Undo](steam-wireless-profiles-2026-11-11.md).


## Latest follow-up: wireless, settings layout and keyboard focus (2026-11-11 evening)

This section supersedes earlier tuning/recovery/acceptance snapshots above. See [wireless investigation](steam-wireless-profiles-2026-11-11.md) and [settings/profile labels](settings-profile-labels-2026-11-11.md) for measured details and negative comparisons.

- Implemented/tested/installed before the final UI follow-up: original 1142 dongle profiles, per-slot full-state parsing, reversible volatile capture, remote unit identity hashed for recovery, bounded periodic capture checks, asynchronous one-in-flight receiver haptics. Actual 17,969 report receipt; user confirmed wireless controls/haptics; off/on state checks passed. A fault test proved capture could be lost while full reports continued; timeout-only recovery failed, explicit capture check recaptured in four seconds. Normal quit repeatedly restored measured original 3/0/1/0/2. Native Windows Steam receiver passthrough and BLE remain unverified/unimplemented.
- Implemented/tested/installed: per-profile controller Labels; shared trailing alignment for settings controls; Steam body controls raised and face captions brought closer. Existing profile JSON and mappings remain valid; old global label preferences are ignored, not copied to every profile.
- Implemented/tested/installed: measured vertical edge-coast correction and optional per-axis Small movement steadiness. User accepted improved slow vertical tracking with X/Y tuned to ~625/439. Do not claim all raw sensor wobble eliminated. User continues adjusting steadiness and haptics; preserve their latest values rather than restoring an older snapshot.
- Keyboard investigation: physical `abcd` doubled with profiles off, Automatic source and fresh app restart; automated single key events did not. Removing idle shortcut listeners produced one user-confirmed single-letter check. Native alert and first SwiftUI sheet still had intermittent keyboard focus going to ChatGPT behind Nokcandu. That initial sheet-only fix is superseded. Current candidate uses an AppKit layer-name field that explicitly makes its sheet the keyboard window/first responder on presentation and click, without polling/forwarding keys. Independent repeated physical acceptance is still required below.
- New user request: optional per-pad Touch haptics with its own strength, independent of movement and all pad modes. One finite burst per new contact, no repeated held pulse, bounded contact chatter, shared ownership/radio output guards; old profiles default off. Two new tests plus full **630 tests, zero failures, 19 optional skips** passed, including privacy. Production packaging and installed hardware acceptance follow below.

Pending validation: repeat New/Rename focus after switching away/back; contact pulse feel on actual hardware; configured global shortcuts (idle-monitor comparison had none configured); broader receiver USB replug/cable swap/multiple controllers; game-level passthrough and remaining overhaul items listed in the priority document. No permissions, pairing, firmware, installed games or saves were changed. No raw controller identity/session logs belong in git.

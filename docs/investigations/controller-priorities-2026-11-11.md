# Controller priorities - November 11 afternoon

User explicitly reprioritized work using the eight-page `11-11-26 Top Priority Prompts.pdf` (six embedded screenshots/photos inspected alongside text). This supersedes the earlier general ordering for this working session. Treat listed symptoms as user observations until receipt/game verification; no wholesale controller rewrite.

## Current checklist

| Priority | Requirement | Status |
| --- | --- | --- |
| 0 | Park BF2 performance and record handoff | Documented below; deferred at user's request |
| 1 | Restore Pro/Xbox game input, identify three Pro aliases, distinguish Steam detection from game receipt | Confirmed and corrected wrong SDL dependency; build/routing/migration tests pass; isolated enumeration succeeds; installed migration and physical DirectInput receipt verified; Trackmania game acceptance pending |
| 2 | Original Steam wired/wireless profile/native support, trackball vs stick/WASD, IMU/touch gating, adjustable edge actions, layout, haptics, desktop duplicate/hold behavior | Wired takeover, independent pad mouse/trackball, X/Y tuning, touch gyro and right-pad haptics installed and user-confirmed; pulse tuning software/UI tested; movement-linked cadence and diagram follow-up below. WASD/edge sprint, wireless and native Windows Steam discovery remain pending |
| 3 | Import existing layer into another profile | Implemented/tested/installed; Import Layer menu and source layers verified in UI |
| 4 | Controller Control+arrows invoke Mission Control/Space switching | Pending event-source/modifier/system receipt investigation |
| 5 | BF1942/BF2 controller click jumps in virtual screen | Shared button-only Wine delivery implemented; both driver builds and real-handler tests pass; game acceptance pending |
| 6 | Verify gyro calibration across focus changes | Same-profile engine retention implemented/software tested; different/no-profile transitions and actual hardware acceptance pending |
| 7 | Battle.net display controls and Overwatch scaled click offset | Pending shared launcher settings support and coordinate regression |

The screenshot's SDL Pro entry is not evidence of Steam Controller identity. Do not hide Apple/MFi aliases on vendor ID/name alone: correlate native/SDL/Windows identities and actual input receipt first. Preserve Steam Input settings, profile assignments and explicit routing choices. No physical controller issue is certified resolved by idle enumeration or synthetic engine tests.

## BF2 handoff (deferred)

User reports deployment menu now visible on Wake Island and Dalian Plant, but roughly 1 FPS online on Wake Island and 10-20 FPS in Dalian Plant single player at minimum settings. BF2Hub.exe launching BF2.exe remains the normal verified login route; do not bypass it as an equivalent test. Latest performance inspection under selected DXMT found actual WineD3D/OpenGL loaded in the D3D9 game; memory pressure was healthy. Older 3D games selected for a newer D3D9 comparison with the legacy DirectX 8 bridge removed. Actual subsequent FPS improvement is unverified.

A reversible BF2-specific menu component and central preservation of component environment/DLL requirements are implemented. Old inline-only transport was ineffective in the legacy renderer; a config-file probe verified the real renderer accepts the final BF2-scoped file. Linked-parent path correction and a central save safeguard are in source. Earlier installed component file was verified on the external game folder; later save dropped the selected file-path key, prompting the central safeguard. Final source passed the full suite (589 tests, zero failures, 19 optional integration skips); the last exact-source packaging/install verification was interrupted by reprioritization and must be checked at the next ordinary controller build. Do not claim the final build is installed solely from prior UI receipts. Detailed evidence/Undo: [BF2 deployment menu](bf2-deployment-menu-2026-11-11.md).

No further BF2 performance tuning is planned until the user resumes it. Controller click routing remains in scope even where BF2 also demonstrates it.

## Controller runtime dependency correction

Confirmed regression: the earlier custom Wine 11 controller bus selected `libSDL2.dylib` (SDL 2.0.20), whereas the stock engine selects `libSDL2-2.0.0.dylib` (SDL 2.32.64 compatibility runtime). Both coexist in Frameworks. Loading the old library was a build mistake, not evidence of a Steam Controller reporting itself as a Pro Controller. The corrected build explicitly links/selects the stock versioned runtime, verifies its actual Mach-O install name, checks generated Wine configuration, and refuses an old-library fallback. The source helper is included in packaged build sources.

Passive host inventory after the user connected Xbox identifies USB 057e:2009 Pro, BLE 045e:0b13 Xbox, USB 28de:1102 wired Steam, and receiver 28de:1142. Receiver interfaces are not additional powered controllers. SDL 2.32.64 enumerates the three actual controllers with valid mappings.

Controlled A/B in one disposable Windows prefix, with only the controller bus replaced between runs and its server stopped between modes:

| Driver / mode | DirectInput | XInput |
| --- | --- | --- |
| Earlier custom bus / default conversion | Xbox and generic Apple 05ac:0001 Pro | 1 Xbox slot |
| Corrected bus / default conversion | One Xbox, one correctly identified Nintendo Pro, one Steam Controller | 3 slots |
| Corrected bus / explicit native Nintendo/Valve | One Xbox and one native Nintendo Pro; one Valve vendor HID interface separately | 1 Xbox slot |

The real Steam prefix was not modified by this comparison. Its earlier three-Pro enumeration differs from the fresh-prefix baseline and may include cached/other-reader aliases; do not claim every installed alias is repaired until fresh installed receipt. Native Valve proprietary HID is not a DirectInput gamepad. Windows Steam proprietary discovery remains a separate unresolved gate. Converted Steam exposure through SDL is standard gamepad functionality, not proof of original touchpad/gyro passthrough.

Validation so far: real Wine bus rebuild succeeds and binary contains the versioned SDL name; 14 build-script tests pass (including real Mach-O coexistence/missing/mislabeled fixtures); 14 routing/alias/migration Swift tests pass. A nonexclusive all-device Windows input receipt was added, compiled with warnings as errors, and started for physical acceptance. No game-input fix is certified from enumeration alone.

Fresh installs package the corrected module. Existing recognized stock/owned Wine 11 installations use the existing idle-only, fingerprinted atomic migration with first-original backup; disabled or manually modified drivers stay untouched. No controller mapping, pairing, Steam Input setting or game data migration is needed. Undo remains the controller compatibility component's original-driver restore and persistent opt-out, available while that environment is closed. Final signed install and physical/game outcomes are pending.

### Installed and physical receipt

Signed update installed with signing continuity and strict/deep verification under normal Mac trust access. Opening Trackmania's Test Controllers through Nokcandu migrated the shared Steam bus to the corrected dependency; binary and migration stamp verified. Saved native route, global profiles-off state and profile assignments were preserved. Full suite rerun: 589 tests, zero failures, 19 explicitly optional integration skips; all privacy tests passed. Restricted signing verification initially reported trust/identity errors; normal Mac trust verification passed, so no signing override or permission reset was used.

The first 180-second receipt ended before physical button input. The user repeated A and left stick on Xbox and Pro during a 300-second installed-driver receipt: both acquired successfully, 30,858 samples each, zero read failures; Xbox 2 button transitions/47 axis changes and Pro 4 button transitions/19,128 axis changes. High Pro axis-change count includes idle analog jitter and is not an idle drift certificate. This establishes live Windows receipt for both actual devices, not correct mapping of every control or Trackmania gameplay. Native Pro exposes DirectInput; Xbox exposes XInput. Game support/Steam Input translation is a separate boundary.

## Layer import increment

The profile editor adds Import Layer → source profile → layer. It copies explicit layer settings to a new layer, generates collision-free names/IDs, rewrites self-layer references, and privately clones referenced macros and radial menus recursively (including inherited macro/menu definitions). Existing destination base/bindings and dependencies are unchanged. Missing referenced layers/devices, missing source dependencies, and engine layer/macro/menu limits reject atomically with an actionable message. Inherited base settings, profile-wide sources and sequences remain outside this explicit layer-copy operation; the UI explains that scope. Three tests cover settings/self references/name collision, nested inherited dependency copying/ID collision, and rejection without partial changes. UI/install verification pending. Undo uses the editor's existing undo history or removes the newly imported layer; no automatic profile migration.

## Shared controller-click correction

The prior architecture delivered controller motion through Wine's relative queue but clicked with a CGEvent at the Mac cursor. Wine's ordinary mouse-button handler includes an absolute movement on every click, so that stale coordinate could reset the Windows cursor, especially inside virtual/scaled presentation. This is independent of the physical mouse raw-capture toggle.

Wine 10/11 now expose an optional controller-only button selector: it queues a reserved negative button encoding, retains each down's Wine window for its matching up, and normalizes it in the real mouse handler without MOUSEEVENTF_MOVE/ABSOLUTE. Ordinary mouse events retain their original absolute path. The helper advertises capability only with this driver, so existing/unrecognized drivers retain their CGEvent route. Nokcandu pins socket releases to the down's process; missing release destinations never trigger a fallback absolute click. Raw-cursor click rewriting excludes these positionless events. Held helper button state is atomic across its existing raw/main queues.

Both Wine 10/11 drivers build. The regression test extracts their real mouse handler from checksum-pinned sources, applies the actual patch and compiles/runs it: all five buttons down/up retain normal absolute behavior for physical events and emit identical button flags without movement for the controller encoding; invalid negative encodings are ignored. Swift tests exercise process handoff, failed release, old helpers, failed down and duplicate down. Nine related mouse/import tests pass. This proves the delivery contract, not BF1942/BF2/Overwatch gameplay acceptance; signed install and Import Layer UI verified; affected-game mouse acceptance pending.

Scope: shared controller mouse clicks for every compatible Wine game, including headphone/controller profiles. No game-specific cursor override is introduced. Fresh installs bundle the matching helper/driver. Existing owned drivers/helpers update through their normal safe generation/migration while closed; unsupported/manual driver edits retain old path. Undo is the prior signed app/helper/driver build through the existing reversible installation/driver restoration flow. Profiles and game data are unchanged.

## Steam Controller takeover and repeated keyboard input

User reports physical MacBook keyboard duplication while testing the Steam Controller. Switching all profiles off did not stop it. Closing Nokcandu did. Reopening Nokcandu with profiles off on Controller on the Mac (Steam test page closed) gives normal typing. Thus current evidence narrows the problem to the active reader/test path, not generic application startup or merely an active mapping profile. No cause/resolution claim yet. User explicitly permits changing test profile choices and requests exclusive controller desktop ownership while Nokcandu handles it. Do not infer permission to destroy games/saves.

The selected-settings query on actual wired 28de:1102 returns left pad mode 3, right pad mode 0, lizard mode 1, IMU mode 0, packet version 2. Controller firmware desktop mouse/keyboard was active and sensor reporting disabled. A bounded two-second hardware mode trial set only these volatile settings (pads NONE, lizard OFF, raw IMU bits added; packet version preserved), read them back exactly, then restored the original settings and verified the restoration. No mapping clear/default/reset, pairing or firmware commands were sent. This confirms mode exchange/restoration feasibility, not motion-axis correctness or keyboard duplication resolution.

The USB reader now acquires this checked mode lease before reading, fails closed if takeover cannot be verified, and restores on last listener/normal application termination only if the same connection still has its applied settings. A local recovery receipt supports retry after an interrupted process; another connection or changed settings owner is never overwritten. The receipt contains connection registry ID and selected settings only, no serial/account information. Reconnection to a different registry ID deliberately does not restore an old connection's settings. Simultaneous Steam ownership/digital-map changes are not fully verified. Three codec/lease tests cover bounds, unexpected/duplicate tags, IMU bit retention, packet-version preservation, JSON recovery and avoiding other-owner restoration. Seven existing raw-report tests also pass. Signed build/full-suite/live reader check pending.

Primary protocol evidence: [Valve-maintained SDL constants](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/steam/controller_constants.h), [feature message structures](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/steam/controller_structs.h), and [SDL Steam controller driver](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_steam.c). The old passive-only source description is superseded by this reversible mode lease. Left-pad WASD/edge sprint, independent right-pad relative/trackball, touch gyro gating and wireless support remain pending; do not describe current right-stick velocity emulation as trackball.

### Installed takeover acceptance

Final takeover build passed 597 Swift tests (19 optional integration skips, zero failures, privacy tests passed), stable signing verification and reversible installation. Installed UI shows desktop controls captured. A fresh hardware read-back while the profile/test was active returned 7/7/0/24/2. User confirmed normal physical keyboard typing with this active reader. Turning profiles off and leaving the Steam test page restored 3/0/1/0/2 exactly. This is a successful controlled duplicate-keyboard retest and actual installed acquire/release verification, not a blanket claim about all input conflicts.

### Independent trackpad / trackball increment

User authorized the remaining minimum right-pad trackball aiming, then explicitly requested the option independently for either pad and a handoff document. Optional per-pad profile settings now choose existing mappings, relative trackpad mouse or trackball mouse. Defaults preserve current profiles. Sensitivity/inversion/decay are adjustable; this increment's choices apply across layers. Finger landing anchors without movement; stationary contact does not keep turning; lift coasts only after recent motion; touching again stops; profile/source/focus/stale-input teardown cancels. Right-pad mouse modes suppress its virtual right-stick axis contribution while preserving physical joystick/triggers. Native/disabled routes suppress conversion. Preview shares the same processor and pointer-menu selector path.

The focused cadence/status-report test initially caught momentum being erased by finger-up reports; corrected before packaging. Six focused tests now pass. Full suite: 603 tests, 19 optional integration skips, zero failures. Signed build/install/UI and actual aiming feel are pending at this checkpoint. [Final handoff](controller-handoff-2026-11-11.md) will record final installation and remaining work. Left-pad WASD/edge sprint and touch-gyro gating remain outside this minimum increment.

### Final trackball install

Final update passed 605 Swift tests, zero failures, 19 optional integration skips; privacy tests passed. Strict/deep signature and continuity verified; recoverable install completed. Only the installed Applications executable was running. Installed UI and saved profile both verify right Trackball mouse at sensitivity 1500 and half-life 0.16 s; left independent chooser verified with legacy behavior retained. Updated-copy reader lock prevents concurrent takeover, including close-on-exec and linked-path rejection tests. Physical trackball/game acceptance remains pending. Detailed source map, Undo, known limits and next priorities are in the [final handoff](controller-handoff-2026-11-11.md).

### Follow-up requested after baseline trackball test

User confirmed baseline operation, then requested X/Y sensitivity, touch gyro and movement haptics, and reported upward/reversed lift flings. A passive twenty-lift capture confirms anomalous still-touched tail coordinates; the coast derivative was using that tail. Robust history-based launch velocity and a measured-fixture regression are implemented without delaying ordinary finger input. Optional axis tuning, actual-engine touch gating with off-hold priority, and short rate-limited movement haptics are implemented with eleven focused tests passing. Hardware accepted a finite haptic command, but felt strength/pad identity remain user gates. Latest details/status are in the [handoff follow-up](controller-handoff-2026-11-11.md).

### Final installed pad follow-up checklist

- **Implemented / tested / user verified:** corrected release fling direction, right-pad haptic output, gyro active only while selected pad is touched. User replies explicitly confirmed all three. Independent X/Y tuning installed.
- **Implemented / automated and installed UI tested:** per-pad pulse rate and spacing independent of strength; four new tests bring the suite to 615, zero failures, 19 optional integration skips. Subjective pulse feel pending.
- **Implemented / tested / configured:** global gyro-only notification switch off; layer/master and calibration notifications remain on. Existing profiles/defaults preserved.
- **Pending:** left-pad WASD/edge sprint, wireless support, broader Steam coexistence and game acceptance remain as listed in the handoff. Earlier statements that touch gyro/right-pad haptics remain unimplemented are superseded.

Recoverable signed install completed; only the installed Applications executable is running. [Current state, tests and Undo](controller-handoff-2026-11-11.md).

### Movement cadence and diagram acceptance checklist

- **Implemented / tested / installed UI verified:** optional movement-matched pulse cadence, with fixed-rate fallback and preview/runtime duplicate-distance prevention. Maximum rate and burst spacing remain independent.
- **Implemented / built / visually verified:** Steam-specific control placement, center Back/Steam/Start row, compact ABXY with outward action captions, and explicit rear labels. Bindings unchanged.
- **Tested:** 616 Swift tests, zero failures, 19 optional skips, including privacy tests; final focused tests after UI refinements pass. Signature continuity/recoverable install verified.
- **Pending hardware acceptance:** subjective speed-linked haptic feel. Existing successful right-pad/touch-gyro/fling retests remain valid within their documented scope.

The installed app retained the user’s 35% strength, approximately 28/s maximum and 2.3 ms spacing; Match cursor movement is on. See [handoff](controller-handoff-2026-11-11.md) for limits and Undo.

### Receiver profile increment

- **Implemented / tested / installed:** original 1142 receiver support in the explicit Steam source; all existing pad/gyro/haptic tuning reused, four slots distinguished from one active controller. 620 Swift tests pass, zero failures/19 optional skips.
- **Hardware verified:** selected-settings query, bounded takeover and exact restore; three-minute input receipt with user-operated A/grips/pads/motion. User confirms installed wireless aiming/haptics and keyboard typing work.
- **Installed state verified:** controller off releases it in Test; wake resumes full wireless receipt and live gyro. Broader receiver/cable replug and native Windows Steam wireless discovery remain pending.
- **UI implemented:** Steam-only on-body controls moved upward by 6% body height; later UI alignment/profile-label requests are a separate follow-up.

The earlier receiver-only inventory and “wireless profile support pending” status is superseded for this explicit source. It is not full native Steam Input passthrough. [Evidence, limits and Undo](steam-wireless-profiles-2026-11-11.md).


## Receiver and editor follow-up checkpoint

Implemented/tested: receiver profile support; identity-checked volatile-mode recovery; periodic ownership verification with bounded baseline recapture; measured vertical edge-coast correction and optional steadiness; per-profile Labels; shared trailing settings alignment and Steam face captions. Full-suite checkpoint 628 passed, 19 optional skips, privacy tests passed; latest capture-guard app build and 18 focused tests passed. User accepted improved slow vertical motion with their new X/Y/steadiness tuning.

Pending: doubled physical typing reproduces even after profiles are off, source is Automatic, and the app is restarted. Automated single presses in the same layer-name field appear once. Haptics restoration/typing comparison is not yet complete. Native Windows Steam receiver passthrough remains unverified. See [wireless detail](steam-wireless-profiles-2026-11-11.md) and [UI detail](settings-profile-labels-2026-11-11.md).

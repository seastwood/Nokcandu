# Controller overhaul implementation and verification

November 10, 2026. The supplied Controller Overhaul v2.0 document is a requirements reference, not evidence that proposed APIs or reported game fixes work. Initial scope was assessment and one independently testable fix. The subsequent request authorizes successive implementation stages across the specification. The inventory below records the initial architecture; the continuation and checklist supersede implementation-status statements in that inventory. No subsystem rewrite or installed-app update.

## Architecture inventory

| Area | Existing implementation and behavior |
| --- | --- |
| Build | `Package.swift`: Swift 5.9, macOS 14 minimum; app → Core + C PadEngine; Core → PadEngine. `build-app.sh` separately compiles the Objective-C Wine helper and C engine for Intel/ARM, signs app/helper, and optionally installs. No new entitlements in this change. |
| Runtime | `Sources/NokcanduPadEngine/padengine.c`, `include/padengine.h`: callback sinks, timed tick/deadline engine, bindings, gyro/tilt, layers, chords, macros and reference-counted held outputs; `pe_release_all` clears held outputs. Layer toggle already exists; persistent key toggle requirements need separate audit. |
| Profiles | `Sources/NokcanduCore/PadProfiles.swift`: Codable profile array in support/controller-profiles.json, default/choice files, inheritance/merge, compiler to `nokpad 1` text, per-environment pad-map regeneration. Atomic JSON writes; not a versioned schema envelope. |
| Mac input/output owner | `Sources/Nokcandu/DesktopPad.swift`: main-actor GameController handlers, background monitoring, 4 ms common-mode timer; one main engine, global lastButtons/lastAxes; focus and profile notifications reevaluate selection. Rule precedence: master off → everywhere → known game → app bundle rule → controller-linked → Mac default. Accessibility check gates compilation. |
| Additional devices | `Sources/Nokcandu/HIDDevices.swift`: non-seizing IOHID manager matches generic desktop joystick/gamepad/multiaxis; DeviceFeed normalizes explicit slots, GC selection uses product name/ordinal. Main controllers exclude additional slots, but share state in DesktopPad. `PadGC` converts GC controls. |
| Editor | `ControllerProfileEditor.swift`, `ControllerProfileSection.swift`, `ControllerProfileExtras.swift`, `ControllerPicture.swift`: SwiftUI updates/persistence, notifications, tester. PadTester sets testerOpen, replaces GC handlers and clears handlers on stop. DesktopPad pauses DeviceFeed while tester owns input. This is direct evidence for interruption, not yet a latency measurement. |
| Mac output | DesktopPad key/flagsChanged, mouse button, wheel and Unicode CGEvents posted at HID tap. Movement first honors 300 ms physical-mouse priority, tries per-PID Unix datagram for a known Wine game, otherwise builds bounded absolute pointer event with explicit deltas. New `PadMouseEvent.swift` isolates movement-event construction for tests without posting. |
| Wine routing | `Sources/NokcanduCore/Controllers.swift`: per-environment WineBus registry native/xbox/hidden/automatic settings, idle-only application; profile needs may force SDL route. These are Wine settings, not global macOS suppression or a virtual Xbox device. |
| Wine helper | `Resources/rawmouse/padmap.m` included in rawmouse.m: interposes SDL wait/open in winedevice, per-controller engines and extra slots, output SDL queue; keyboard/mouse sinks there intentionally do not inject, avoiding duplicate Mac mapping output. Game half publishes pad-active, receives socket events; movement uses captured raw queue, hidden-cursor relative queue, or bounded pointer warp. |
| Raw mouse/capture | `Resources/rawmouse/rawmouse.m`: IOHID/GCMouse physical readers, Wine event-layout verification, captured target queue, cursor association and foreground/hidden-cursor checks. `Engine/winemac/patches-11.0/0003-windowed-presentation.patch` adds presentation/release behavior. This is not generic external-app capture. |
| Integration/storage | `PadProfiles.refresh/write` generates managed maps; helper build hash and existing helper repair/update infrastructure distribute Wine helper changes. ControllerProfileSection handles game choices; Settings/DesktopPad provide standalone rules; GameControllersSection distinguishes environment controller setup. |
| Existing tests | `PadEngineTests`, `ControllersTests`, `ProfileTests`, `RawMouseSummaryTests`, `AppPrivacyTests` and helper/repair tests. New PadMouseEventTests inspect actual unposted CGEvents. Tests do not substitute for hardware/game verification. |

## Confirmed defects and hypotheses

* Confirmed by inspection: desktop movement selected left-drag type when left+right held, but right button argument whenever right held. Extra buttons never selected a drag event. Wine pointer path already gives left precedence over right; this iteration aligns desktop priority and includes buttons 2–4.
* Confirmed structural risks: editor takes exclusive ownership of callback properties; main GC devices share caches/engine; full profile recompile destroys/recreates engine and releases all outputs, including unaffected mappings. A focus change with identical compilation can retain runtime state because evaluate returns early. Disconnect attaches/evaluates without unconditional per-source release. These need dedicated regression fixtures before changing behavior.
* Overwatch delayed aim: unresolved. Candidates include real-mouse priority filtering, socket availability/layout detection, or target consumption. Need correlated route counters and visible response, before/after shot. No claim that drag identity causes this.
* BF1942 click jump: unresolved. Movement and clicks travel different paths (Wine relative socket versus desktop CGEvent at current pointer). Capture may park pointer away from game cursor. Compare event location/deltas and actual response; do not change click routing speculatively.
* Edge stop/Dock: bounded desktop fallback is observable in source; Wine menu fallback also clamps. Whether a given gameplay session incorrectly chooses fallback requires trace evidence. Generic external app capture remains unimplemented.
* Steam Controller: HID matcher excludes vendor-only interfaces; descriptions in Controllers recognize Valve but do not prove usable input. Steam ownership, firmware and connection behavior remain untested.

## Feasibility and evidence boundaries

| Capability | Status |
| --- | --- |
| Keyboard/mouse injection and app selection | Implemented paths; actual delivery depends on Accessibility/target filtering. Unposted CGEvent construction is testable without permission. |
| Relative Wine movement | Implemented private Wine queue integration with runtime layout checks, not proof every game receives it. |
| Native + mapped desktop input | Physical GC input remains visible; mapped output is additive. No suppression backend in DesktopPad. |
| Selective mapped/native Wine routing | Existing SDL interception has per-control behavior, constrained to that environment/path. Requires target-side monitor verification; registry settings require restart. |
| Arbitrary target capture | Research required: lifecycle, multiple displays, spaces, emergency release, permission failure. Existing Wine association code cannot simply be generalized. |
| True virtual controller identity, protected-app injection, AirPods motion | Unverified; no implementation commitment or emulated-identity promise. |
| Steam original 2015 wired/receiver/Bluetooth, Nintendo/8BitDo | Hardware/connection-specific validation required. No live hardware tests performed in this iteration. |

## Reproducibility matrix and diagnostics

Opt in on a development launch with `NOKCANDU_TRACE_PAD_MOUSE=1`. DesktopPad emits at most one aggregate route-count line per second while movement arrives: hardware-priority suppression, wine-socket acceptance, desktop-pointer fallback; latest delta and held-button numbers only. No app/device identifiers or account data. Socket acceptance does not prove game consumption. Existing helper `pad-status` and `pad-active-game` summaries distinguish driver input and game relative/pointer routes; use temporary local evidence, never commit raw session logs. Disable by removing environment flag and restarting. Trace is observational, not a complete input monitor or latency measurement.

| Scenario | Procedure and evidence required | Status |
| --- | --- | --- |
| Desktop drag | Map left/right/middle/back/forward, hold each and both primaries while moving; release left while right stays down, then release right. Inspect event type/button/delta/location and visible drag. | 32 combinations + release transitions automated; visible app pending. |
| Overwatch | Same profile/scene/permissions, gyro and stick separately; trace 5 seconds before/after shot, include physical mouse inactivity >300 ms; compare route and target response. | Pending target game. |
| BF1942 click | Stationary aim then mapped click, then continuous turn/click; record relative/absolute position/delta and capture transitions. Repeat raw capture on/off without altering other settings. | Pending target game. |
| Edge/Dock | Long yaw/pitch in windowed/fullscreen, two displays; observe cumulative deltas, route, edge/Dock and click destination. Repeat unrelated external native/Wine/streaming app selection. | Pending. |
| Routing | Target input monitor, native-only and mixed mapping; one then two same-model devices, additional slots, Steam absent/present. Count callbacks and target inputs independently. | Existing engine tests only; hardware pending. |
| Cleanup | Hold key/click during focus change, disconnect, mode/profile replacement, sleep, permission revocation and quit. Check release and cursor restoration; retain emergency physical escape. | Integration pending; do not infer from release_all unit tests. |
| Editor | Hold/move while open/edit/close; measure callback rate, main-thread time, file writes and output latency. | Handler ownership confirmed; performance baseline pending. |

Do not use compile-only success as acceptance. No unsuccessful game comparisons performed here; avoid re-running the whole overhaul or treating a button-layout preset as virtual-device proof.

## Incremental implementation plan

0. This inventory, opt-in route traces, mouse-event regression tests, baseline engine/routing tests. Remaining Phase 0 gates: target-side event monitor, measured latency, consented hardware matrix and lifecycle tests. Phase 0 is not fully hardware-validated.
1. First isolated fix: correct desktop movement event identity. Next separately investigate click placement and delayed aim with traces; only implement a relative/capture change after comparison. App-scoped capture must have independent owner, explicit opt-in target, emergency release and focus/exit cleanup tests before enablement.
2. Extract routing decisions into testable policy while retaining Wine registry semantics. Label native visibility and unsupported suppression honestly. Add per-device identity/state and disconnect tests before exposing new modes.
3. Share controller observation between tester/runtime, throttle telemetry separately, then introduce immutable runtime snapshots preserving unaffected holds. Implement toggle-key/sequence additions separately from existing layer toggle/chord behavior.
4. Diagnose original Steam hardware modes and Steam coexistence using connection-specific evidence; avoid adding overlapping GC/HID readers without duplicate detection.
5. Standalone virtual-device feasibility spike with signed deployment and target recognition gate, no production backend until proven.
6. Small standalone/notification preferences changes; AirPods research separate and disabled by default.

## Migration and Undo

This first fix changes only Mac output event construction and optional development diagnostics. No persisted schema, game settings, compiled profiles, launcher scripts or Wine helpers change; existing installations receive it when a tested app update is installed. Fresh and existing profiles use the same shared path. No migration or backup is necessary for this change; roll back the app binary/source change to undo. No installation performed here.

Before any later schema change: preserve original bytes in a versioned local backup, validate decoding and compilation before atomic replacement, retain unknown/explicit settings, migrate idempotently and test downgrade/restore. Never regenerate manually edited launchers to deliver controller changes. Wine helper changes must use existing shared generation and safe idle repair/update paths with managed ownership checks.

## Verification result

`swift test --disable-sandbox --filter 'PadMouseEventTests|PadEngineTests|ControllersTests'` with temporary compiler caches: 21 tests passed, zero failures. This exercised actual CGEvent fields (32 combinations and release sequence), engine behavior and controller policy tests. SwiftPM also built the app product; no packaging/install command ran.

After diagnostic integration, expanded selection including ProfileTests, RawMouseSummaryTests and AppPrivacyTests executed 31 tests with four assertions/errors in three AppPrivacy test cases: two `Quit Profile display test first` errors and two expected-nil microphone declaration mismatches. Remaining selected tests passed. Failures concern existing privacy/game-preparation paths outside this change, but baseline equivalence was not established; do not claim full regression success. Initial default-cache attempt failed on compiler-cache filesystem access; temporary CLANG_MODULE_CACHE_PATH and SWIFTPM_MODULECACHE_OVERRIDE allowed execution. `git diff --check` passed. No target game, physical controller, external-app drag, permission revocation or capture acceptance performed.

## Continued implementation November 10

### Progress checklist

Status is deliberately split between implementation, automated verification, and application/hardware acceptance. “Blocked” means a concrete validation prerequisite is missing, not that the requirement was fulfilled.

| Specification requirement | Implementation | Verification and remaining gate |
| --- | --- | --- |
| 0 Architecture/diagnostics/tests | Implemented inventory, reproduction matrix, opt-in route tracing and session diagnostics UI | Tested event fields and pure policies. Target latency baseline and physical reports pending. |
| 1 Native/hybrid/remapping/selective | Implemented Native value routing, legacy button presets, primary-input Hybrid/Mapped presets, selective buttons/sticks/triggers/gyro/touch/tilt | Shared-engine/serialization tests passed. Native macOS suppression, native Wine sensor delivery and persistent per-primary-device routing remain unavailable/pending; explicit extra-device slots retained. |
| 2 Mouse correctness | Implemented consistent drag identity, explicit own-event source/marker, zero-motion click events and captured down/up process/location consistency | Automated CGEvent and ownership tests. Overwatch delayed aim and BF1942 click-jump causes are still hypotheses; target-game before/after acceptance blocked on interactive game/hardware access. |
| 2 Application capture | Implemented independent bundle-ID rules, Disabled/Manual/Automatic, process-directed fixed-coordinate relative events for mapped controller movement and clicks | Policy tests cover foreground, permission, missing window, emergency release. Control–Option–Escape release and Control–Option–C toggle are profile-independent. No global cursor hiding/disassociation, pointer warp or physical mouse seizure. Native/Wine/streaming target acceptance and multi-display behavior need interactive verification; not claimed as universal physical-mouse capture. Explicitly selected wrapper paths now cover their exact direct Nokcandu GameApp helpers; child rules take precedence. Arbitrary third-party helper identity resolution remains pending. |
| 2 Lifecycle safety | Implemented capture release on activation/termination/space/sleep events, permission polling + per-output checks; mapping focus change releases/rebuilds, quit stops mappings/head motion | Pure capture/button ownership tests and engine release tests; OS exit/crash/space/permission-revocation integration pending. Physical cursor never hidden, so this owner has no cursor restoration debt. |
| 3 Editor coexistence | Implemented preview polling instead of taking/clearing runtime GC callbacks; DeviceFeed supports preview sampling without attaching handlers | Builds; sampling does not post real outputs. Visible playing/editor hardware acceptance and end-to-end latency measurement pending. Preview remains 120 Hz; disk-write debounce implemented/tested, optional timing aggregates added, deeper UI telemetry tuning pending. |
| 3 Immediate edits | Implemented binding-only updates, compatible stick/gyro tuning and simple/key-stick output transitions, preserving unaffected owners | Tests verify changed-held release, unaffected hold, replacement on next press and nonmutating rejection. Unsupported structural/mixed changes and edits of active macro/pulse/simultaneous owners use safe replacement; unrelated running actions survive binding edits and compatible tuning/output changes. Ordinary hold/turbo timers survive unrelated binding edits. Equivalent text never restarts the engine. Complete immutable snapshot migration remains pending, so unaffected state is not preserved for every kind of edit. |
| 4 Toggles | Implemented visible Toggle behavior for keys/mouse/controller buttons/triggers, separate from layer toggles | Tests cover persistence, overlapping holds, changed-owner cleanup, partial additional-device disconnect, full release and reactivation. Isolated actual editor UI verified. Game/hardware acceptance pending; controller outputs remain Wine-only. |
| 4 Shortcuts | Implemented modifier-state recomputation across left/right keys; chord order remains modifier/key down then reverse release | Modifier and engine chord tests. Actual Command–Tab/Mission Control invocation blocked on authorized interactive session/system settings. No timing-based universal-hotkey claim. |
| 4 Sequences | Implemented explicit simultaneous chord step; new macros default to 50 ms between adjacent non-wait steps, adjustable to zero; async existing engine timers/cancellation retained | Tests cover chord order, zero-delay nonblocking execution and cancellation release. Existing decoded macros without eventDelayMS keep old timing. Explicit waits are not doubled. Compiled steps respect existing 48-step engine limit without truncating halfway through a chord. |
| 5 Original Steam Controller | Research and session diagnostics implemented; no new report decoder/device-mode writes | SDL source confirms dedicated Steam protocol/mode handling is needed; native reader matcher limitation persists. Wired/receiver/Bluetooth availability and Steam coexistence blocked on original hardware. No Steam process killed or forced-release mitigation. |
| 6 Wider controller support | Existing GC and generic HID paths preserved; diagnostics identify exposed hardware and reader presence | Connection-specific Nintendo/Switch 2 Pro/8BitDo/Xbox/PlayStation matrix remains unverified. 8BitDo toolkit reviewed as model-specific GPL firmware context only; no code or flashing behavior reused. |
| 6 Virtual controller | Research only; no synthesized identity/driver shipped | CoreHID exists in local SDK at macOS 15+, above app minimum 14; Apple documents virtual HID entitlements/DriverKit deployment. Signed authorized creation, target recognition and latency matrix remain unproven. No bypass or identity spoofing attempted. |
| 7 Standalone UX | Existing standalone profile activation retained; Login moved to General Startup; dismissed setup remembered regardless of Wine readiness | Builds. User dismissal no longer depends on game-engine setup. Menu-bar/profile activation state retained. Additional onboarding review pending. |
| 7 Gyro notifications | Implemented independent automatic-calibration preference; manual calibration feedback overrides general HUD suppression | Calibration-kind engine test covers manual completion then automatic restart. Preference never disables calibration. UI visibility needs manual check. |
| 8 Multi-input/head tracking | Main-controller state now retains source identities and composes held buttons/strongest axes deterministically; experimental CMHeadphoneMotionManager path added, session-only off by default | Tests cover two-source release/axis arbitration, angle wrap, discontinuities, recenter, dead zone and invalid input. Requires packaged motion description, capability check and user opt-in; no pairing/audio API changes. AirPods motion/audio coexistence blocked on compatible hardware and permission; availability is not support certification. |
| 9 Architecture separation | Added Core policies/event constructors/source composition, independent capture owner, diagnostics/experimental owners | Incremental extraction only. Runtime remains main-actor C engine; no whole-subsystem replacement. |
| 10 Input monitor | Implemented opt-in Settings session counters: GC callbacks, gyro receipt age, key/mouse emissions/routes, focus, profile, Accessibility, capture, Steam presence, enumerated hardware/transport | No raw reports, descriptors or account/session logs collected. Transformed-event timeline/input-to-output latency and permission-type breakdown pending. Emission counts do not prove consumption. |
| 11–13 Delivery/regression gates | Incremental automated checks and shared helper build; no installation | Entire specification is **not complete**. Full target-app/hardware matrix and signed virtual-device feasibility remain release gates; pending software scope is explicitly listed above. |

### Capture behavior and safety limits

`PadCapture.swift` owns only controller-generated pointer routing and never manipulates another process's cursor association. At a target window's center, CGEvents carry unbounded relative deltas and are posted to that PID. Desktop pointer coordinates are not accumulated; clicks use the same anchor, and releases remember the down-event's destination even if focus changes. That is a bounded implementation approach to the screen-edge/Dock problem, not evidence a particular game/streaming client consumes those events. No continual warping comparison was needed because no new warping path was introduced. Physical mice retain their normal behavior. If a target rejects injected events, this feature cannot promise aiming support.

Policy starts disabled for every app. Automatic capture follows that app's foreground identity; manual activation is discarded by focus changes. Emergency release suppresses reactivation for the same foreground PID until explicit toggle or a foreground identity change. Space/sleep release uses the same latch. No persisted “captured now” flag is restored on launch. A missing eligible target window or Accessibility access leaves capture unavailable. The global emergency shortcut is observed through the existing Accessibility-dependent NSEvent mechanism; permission failure does not grant capture. UI focus/Space behavior and event delivery must still be checked on a real desktop before release.

Mouse events now request a private event source and carry an explicit marker. The physical-mouse monitor ignores that marker or own PID and ignores events with no CGEvent, eliminating reliance solely on a default source PID. A construction test initially tried to allocate a fresh private event source in the restricted test session and got nil; the test now verifies marker fields on actual unposted events and tests classification inputs independently. This environment limitation is not evidence about game delivery or a reason to claim latency fixed.

### Live update and source semantics

`pe_update_bindings` accepts only changes to bind lines with all nonbinding configuration identical. Ordinary hold/double/turbo timers are retained for unaffected inputs and cancelled for changed inputs. Changed text still falls back during pulse/simultaneous/macro/key-or-mouse-toggle/menu states; equivalent text is always a no-op. It parses a candidate, releases altered bindings, updates the table at stable addresses, and leaves unaffected holds/layers intact. Rejection does not mutate the old engine; DesktopPad/preview fall back to release-and-rebuild. Runtime movement additionally checks foreground identity at tick time to avoid a stale foreground held axis. Source composition is explicit: buttons OR across main GC sources; axes choose greatest magnitude, stable source identity breaks ties. Additional configured devices still have their existing independent slots. This fixes accidental shared-cache release/neutral overwrites but is not a persistent hardware identity model or per-device profile engine.

### Migration and Undo for continued work

Older profiles decode with routing/toggle/chord/delay additions absent and keep existing compiled behavior. New features are additive to the existing profile array rather than rewriting it into an incompatible envelope. Before first saving new-feature data, saveProfiles preserves the previous file bytes in `controller-profiles.json.pre-controller-v2` using no-overwrite creation; failure blocks the write. Later saves preserve that backup. Automated tests confirm exact backup bytes, no overwrite and new-data round trip. No on-disk user profiles were edited in this session.

Rollback: quit Nokcandu, preserve the current profile file separately if it contains newer edits, restore the `.pre-controller-v2` bytes to the original filename, then roll back the app. The backup is a pre-feature snapshot, not a rolling history; restoring it can omit subsequent edits. App capture rules use a separate `padAppCaptureModesV1` preference and default disabled; old apps ignore it. Login uses the existing system service; moving the control performs no registration. Existing HUD preference remains; the new automatic preference defaults to the previous visible behavior. Head tracking never persists enabled state. `NSMotionUsageDescription` is added only to future packaged builds; no permission prompt was invoked.

C engine changes are built centrally into both the Mac app and shared Wine helper. build-app's existing content hash includes C engine/header changes. Future distribution must use normal managed helper refresh/idle migration and preserve manually edited launchers; old running Wine helpers must be restarted/upgraded before relying on new route/toggle behavior. No packaged helper was copied into an installation, no system permission was modified, and no game/save/launcher binary was changed. Undo source changes or roll back a future app/helper update together; do not pair a new compiled mapping with an old helper and claim feature parity.

### Privacy failure baseline

Exported unchanged HEAD into an isolated temporary directory and ran AppPrivacyTests with temporary compiler caches. All four failures reproduced: two `Quit Profile display test first` errors and two retained microphone-purpose assertions. The same four recur with current controller changes. `/bin/ps` itself returns Operation not permitted here; GameLauncher.loadProcessRows therefore yields an unreliable scan, runState is `.unknown`, CustomGames.save refuses mutation, and AppPrivacy.prepare conservatively retains opt-in metadata when it cannot prove a host/sibling stopped. These paths explain the failures without requiring a controller regression. Do not weaken unknown-process safety or alter real games to make this environment's fixture tests pass. Baseline and candidate logs remain temporary and are not committed.

### External research and capability matrix

Primary references checked November 10, 2026:

* [Apple cursor association](https://developer.apple.com/documentation/coregraphics/cgassociatemouseandmousecursorposition(_:)): foreground-app semantics; not a documented general background capture API.
* [Apple CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent): process-directed event posting exists; application acceptance remains empirical.
* [Apple GameController platform notes](https://github.com/apple/game-porting-toolkit/blob/main/game-porting-skills/skills/using-game-controller/reference/platform-notes.md): background monitoring does not capture/suppress a foreground app's controller events.
* [SDL original Steam Controller backend](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_steam.c): dedicated report handling and lizard-mode feature reports. This supports the need for a connection-specific investigation, not copying feature writes without hardware verification. Do not silently switch modes while Steam is running.
* [8BitDo Ultimate 2C toolkit](https://github.com/carlosbrownef-source/8bitdo-ultimate-2c-toolkit): GPL-3.0, model/firmware-specific controller/dongle changes; no code reuse or firmware flashing incorporated.
* [Apple virtual HID entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device) and [HIDDriverKit](https://developer.apple.com/documentation/hiddriverkit): creation/deployment permissions require their own signed feasibility spike. Local SDK confirms CoreHID/HIDVirtualDevice availability at macOS 15. Reading an SDK interface is not a target-app recognition test. Virtual Xbox/DS4/Nintendo identities remain unavailable, not faked with layouts.
* [Apple headphone motion](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager): macOS capability availability and required motion description. Local SDK confirms macOS 14 minimum. [mousepods](https://github.com/starman-tech/mousepods) remains conceptual Linux context; the implementation uses Apple's API instead and does not adopt its protocol.

| Hardware/application family | Wired | Receiver | Bluetooth | Steam/streaming coexistence |
| --- | --- | --- | --- | --- |
| Original 2015 Steam Controller | Unverified; dedicated reports needed | Unverified | Supported-firmware configurations only, unverified | Unverified; compare session gyro receipt before/after Steam; never infer exclusion solely from a gap |
| Existing Xbox/PlayStation | Existing GC/generic path retained; not physically retested | Unverified | Existing path retained; not physically retested | Unverified |
| Switch Pro / Switch 2 Pro | Unverified per model | Unverified | Unverified per model | Unverified |
| 8BitDo models | Generic HID/GC exposure depends on model/mode | Unverified | Unverified | No firmware mutation |
| Motion-capable AirPods | Not applicable | Not applicable | Experimental documented API, hardware unverified | Audio continuity unverified; no audio reconfiguration |
| Native / Wine / Moonlight / other streaming target | App rule selection available | Not applicable | Not applicable | Process-directed event consumption unverified; no blanket support claim |

### Manual acceptance still required

Use a development build without installing it, after explicit permission for any required macOS consent. For capture: select the actual foreground app bundle, choose Automatic or Manual, activate its profile, hold a stick through several revolutions, click/release while turning, then change focus, desktops, sleep and quit. Confirm desktop pointer/Dock stays unaffected by mapped events, relative yaw continues, release shortcut stays effective, and unrelated apps receive no captured down-events. Repeat native app, known Wine game and streaming client, each windowed/fullscreen and across displays. Observe physical mouse separately; it is intentionally not captured by this implementation.

For editing: hold an unchanged key while editing a different binding; remove a held binding and verify immediate release; try a nonbinding change and note the documented full-rebuild fallback. Open/close multiple profile editors while moving. For routing, use target-side controller and keyboard monitors, including two same-model controllers and additional-device slots. For toggles/sequences, disconnect/focus/quit while an output is held or a sequence delayed; test system hotkeys with the user's actual shortcut configuration. For Steam, keep connection mode fixed, enable diagnostics, compare gyro timestamps/callback counts before/after Steam, and repeat receiver/wired/firmware-supported Bluetooth separately. Head tracking must remain off until explicitly enabled with compatible hardware; confirm motion, recenter and audio together.

### Final checks for this continuation

* Final selection `swift test --disable-sandbox --filter 'Pad|ControllersTests|ProfileTests|RawMouseSummaryTests|AppPrivacyTests'` with temporary compiler caches: 73 test cases executed. Four assertions/errors remain in the same three baseline AppPrivacy cases; all selected controller/profile/raw-mouse tests passed. This is not an overall green suite.
* The shared Objective-C/C helper compiled successfully as a universal x86_64/arm64 dylib into a temporary output, including the Wine reload path wired to pe_update_bindings. Existing OpenGL deprecation warnings remain. No helper install or app packaging/install was performed.
* `git diff --check` and `bash -n build-app.sh` passed. App products compile as part of swift test. UI rendering and actual event injection were not exercised.
* Final review found and fixed mapped-only unbound fallback: explicit mapped routes now suppress the engine's legacy native fallback. Both/native/disabled tests cover unbound controls. Existing behavior remains the default for profiles without routing fields.
* Final review also found the existing macro held-output store only tracked six downs even though sequences permit 48 steps. Expanded the macro hold ledger to the step limit and release in reverse order; tests verify eight held keys release at completion and cancellation with no delayed leftovers. This is shared engine cleanup, not a per-game workaround.
* No source changes to privacy policy, no altered system permissions, no process termination and no installed game/content/save/profile changes. Unrelated untracked backups/scripts were left intact.

Process inspection via ps and fresh private CGEventSource creation remain unavailable to the command/test session. Subsequently authorized computer control can inspect the actual Mac UI, as recorded below; target-game/hardware before/after evidence for development changes is still absent. Further assertions about Overwatch/BF1942, physical capture, Steam device-mode changes or virtual-controller recognition would be speculative. Pure software gaps are listed as pending rather than falsely blocked or complete: full per-axis routing, complete runtime snapshot swaps, debounced persistence, robust persistent device identities/helper-target resolution and measured latency still need follow-up implementation. Do not release/install this work on the strength of construction tests alone.

Final app-only build also passed after preventing experimental head movement in Native-only profiles and changing capture status text to describe routing rather than imply target acceptance. These final guards do not activate motion, capture or permissions. No installed app was launched.

## Live timers and authorized Mac inspection continuation

### Implemented and tested

* Binding-only live edits retain unrelated hold/double/turbo timers. Changing a binding cancels its old hold/double/turbo deadlines, releases its owned outputs and waits for a new physical press before activating the replacement. Active simultaneous pairs, pulse stores, macros and latched key/mouse outputs remain conservative fallbacks for changed text; full snapshots remain pending.
* Turbo press state now records whether its outputs are actually down. Previously a turbo off-phase release decremented shared key/mouse reference counts again and could release another input's hold. Both normal release and live editing now skip that extra release. Tests cover an overlapping held key, edits during both turbo phases, pending hold cancellation, preserved unrelated deadlines and no delayed leftovers.
* Re-saving identical compiled text is a no-op even during an active toggle or sequence. This prevents a forced refresh or equivalent Wine map rewrite from clearing a working latched output/sequence. Tests verify subsequent toggle-off and the original sequence deadline still work.
* Manual capture discards activation after permission/window loss or a rule-mode change. Restoring a window/permission no longer revives manual capture without another explicit toggle. Toggle requests for a stale foreground PID are ignored. Automatic mode remains foreground-scoped. Disabled capture rules no longer enumerate desktop windows on each poll.
* These are shared C/Core paths; DesktopPad, preview and Wine reload already use the shared update API. No schema change or additional migration is needed; pre-v2 backup behavior is unchanged. Undo these source changes together with a future corresponding app/helper update; no installed update was performed.

### Actual Mac UI evidence

The user explicitly authorized taking control of the Mac for testing. Through computer control, inspected the existing installed Nokcandu app and restored its library window afterward. Observed installed version 0.12.14, a Pro Controller assignment row (which may be remembered rather than connected), Mac profiles enabled, and an Everywhere Overwatch profile. Steam and VoidLink were running in the app inventory; Overwatch and Battlefield 1942 were available but not running. These observations supersede any blanket statement that the desktop is wholly inaccessible. They are baseline inventory, not verification of the development build or game aiming. No settings changed, profile editor opened, game launched, permission granted or software installed. Physical stick/gyro movement was not simulated. Existing active mapping was preserved.

The initial bundle-ID lookup was ambiguous because several app copies share that ID; selecting the actual installed app by full path resolved it. Avoid launching an arbitrary staged/backup copy by bundle ID when testing. UI inspection showed the old settings layout, confirming it does not yet contain the development changes.

### Continuation verification

Final selected regression run: 83 tests executed, with exactly the same four assertions/errors in the three baseline AppPrivacy cases; all controller/profile/raw-mouse cases passed. The shared helper again compiled for x86_64 and arm64 with only existing OpenGL deprecation warnings. `git diff --check` passed. No install or system-permission changes.

Added `Tools/controller-probe/main.swift`, a process-local, three-second receipt-only GameController probe. It does not inject events, enable sensors, pair/discover controllers, modify device modes or save profiles. Compiled and ran successfully; it observed zero controllers/control callbacks/motion callbacks in this command execution context. This does not establish Steam exclusion or incompatibility. The earlier commentary calling the Pro Controller connected was too strong: ControllerLinks displays the union of connected names and remembered assignments. Corrected the baseline evidence above. System Settings search produced a Game Controller settings result but did not open a controller-status page reliably; restored its original Login Items/startup-search view without changing any switches. Actual connected hardware and gyro delivery remain unverified.

## Compatible live tuning and exact wrapper targeting

### Checklist update

* **Implemented/tested:** shared `pe_update_profile` dispatches binding-only updates or compatible stick/gyro tuning in place. Mac runtime, preview and Wine helper use the same API. Tuning preserves raw stick positions, acceleration/integrators, held buttons, toggles, timers, running sequences, calibration state and active layer. Changed gyro filtering resets only its smoothing history; new sensitivity applies to the next sample. Gyro output/default/calibration-mode changes, stick mode/destination/key changes, layer-configuration presence changes, flick-stick configurations and mixed binding-plus-tuning changes retain safe full replacement. Complete snapshot swaps for every edit remain pending.
* **Implemented/tested:** `PadApplicationTarget` recognizes the exact generated `<Wrapper>.app/Contents/SharedSupport/GameApp/<Child>.app` layout. Capture inherits a wrapper rule only when that wrapper's canonical path was explicitly selected; direct child rules, including Disabled, take precedence. Native/streaming app rules still match their bundle IDs directly. Same names in other folders and arbitrary Helpers layouts do not inherit capture. Capture status continues naming the actual foreground app.
* **Corrected by inspection:** DesktopPad no longer falls back to matching an unrelated library game by name when its helper's host does not match. It uses the shared exact-layout recognizer plus canonical Wine host and game name. A stale/mismatched wrapper now falls through to normal app/Mac rules rather than assuming another game's identity. Actual known-wrapper behavior still needs desktop verification.

### Evidence and regression boundaries

Six new live-tuning tests verify continuous mouse speed changes without a new axis event, next-sample gyro scaling, preserved acceleration, retained latched outputs/running macro, retained layer, and rejection of structural output changes without mutation. Two targeting tests verify exact selected host, same-name different host, missing selection provenance, invalid helper layout, direct streaming rule and child Disabled precedence. An initial targeting test failed because URL directory metadata differed; canonical path comparison corrected it. Keep path identity checks explicit instead of treating display names or file-URL directory flags as process identity.

Final selection ran 91 tests. All selected controller/profile/raw-mouse tests passed; the same four baseline AppPrivacy assertions/errors remain. The app products compiled through swift test. Universal Wine helper rebuilt successfully for arm64/x86_64 with existing OpenGL deprecation warnings. `git diff --check` passed. No hardware/game acceptance, installation, permission change or real profile mutation occurred in this continuation.

### Fresh install migration and Undo

No profile schema change. The existing pre-v2 backup remains unchanged. A separate `padAppCapturePathsV1` preference records only application paths chosen through Add an Application; existing capture-mode preferences are retained. Old selections without recorded paths continue direct bundle-ID behavior and do not automatically expand to child helpers. Re-select a wrapper to opt into its helper relationship; its current mode is preserved. Remove/disable its rule to undo capture, or roll back app/Core/helper changes together. No launcher regeneration or installed-content migration is needed. App moves require re-selection for inherited helper matching; native direct bundle rules continue working. Broader executable identity and third-party wrapper discovery remain pending, not inferred.

## Axis routing persistence and real Pro Controller receipt

### Progress update

* **Implemented/tested:** selective routes for left/right stick groups, left/right triggers and gyro. Native bypasses that input's mapping; Mapped emits configured mappings; Both retains raw stick/trigger values plus mapped actions; Disabled suppresses that input's engine contribution. Contributions to the same logical axis choose the stronger value instead of doubling. These are Wine/shared-engine output policies, not global physical-device suppression. Native gyro delivery through Wine is not implemented/certified; Native input values also does not restore an original Windows device identity when the existing profile driver is Xbox-style. Existing profiles without controlRoutes keep their previous behavior, and existing Hybrid/Mapped-buttons presets keep their button-only scope.
* **Implemented/tested:** optional inherited `controlRoutes` profile data, per-control editor pickers and pre-v2 backup detection. Round-trip and parent/child override tests cover the new field. Native/streaming/macOS apps retain original physical-controller visibility. New routing lines use existing full engine replacement, releasing old owned actions; routing changes do not yet use a state-preserving snapshot swap.
* **Implemented/tested:** `PadEditQueue` exposes every committed editor value to runtime immediately while coalescing persistence for 250 ms. Latest-generation checks protect against stale cancelled callbacks. Shared-profile and game-specific own-profile scopes are separate, even if their IDs coincide. Close and normal quit flush pending saves; lifecycle wiring is in editor/AppDelegate. Before delete/rename/duplicate/export/import/default changes, UI actions flush pending saves; deletion tests ensure stale jobs cannot resurrect a deleted profile. Persistence errors remain reported by existing callers; removing the pending overlay returns runtime to durable state. A process crash can still lose the last 250 ms of pending edits. Concurrent editors are latest-commit wins, not a field-level merge.
* **Pending:** profile-wide full-axis Hybrid/Remapping intent, touch/accelerometer routing, persistent per-physical-controller routing, full snapshot updates for structural edits, measured UI write reduction in an actual playing/editor session and end-to-end target event consumption.

### Automated checks

Latest selection before hardware probing: 98 tests executed, all selected controller/profile/raw-mouse tests passed; only the same four baseline privacy assertions/errors remain. Targeted debounce/routing/live-edit selection also passed. Runtime tests cover all four stick/trigger/gyro routes, no same-axis doubling, release cleanup, inherited compilation/backup, immediate runtime visibility across 100 edits with one final save, independent own/shared scopes and stale timer rejection after deletion. App products built through swift test. No user files or installed binaries were changed by these tests.

### Hardware evidence

The user confirmed a Pro Controller was connected. A temporary standalone AppKit receipt probe then showed one Pro Controller, an extended gamepad and motion object, and continuous motion callbacks (over 4,500 observed, last report age zero seconds). The native app inventory simultaneously showed Steam and installed Nokcandu running. The probe did not activate sensors, discover/pair devices, write controller reports, load a mapping engine or inject events in this first receipt check. This establishes simultaneous sensor receipt for this observed Pro Controller session; it does not prove original Steam Controller compatibility, all connection modes, game aiming or absence of every Steam conflict.

The unbundled command-line probe had seen zero devices earlier. Do not equate that command execution context with the GUI app's capabilities. After the receipt check, the temporary probe and Activity Monitor used for cleanup were verified closed. Ordinary probe keyboard close shortcuts were initially absent because the minimal diagnostic app had no standard menu; a later source revision adds an explicit Quit item. A narrow command-line cleanup attempt failed because process enumeration is denied; the actual cleanup used Activity Monitor's normal Quit for the temporary probe only, not Force Quit and not any user app. No permission or installed mapping setting changed.

## Ownership, recovery and test delivery continuation

This section supersedes earlier pending statements for primary-axis presets, touch/tilt routing, disk debounce, toggle source cleanup and privacy-test status. Hardware acceptance gates remain open.

### Current progress checklist

| Requirement | Status and remaining limits |
| --- | --- |
| Critical mouse reliability/capture | Implemented/tested event identity, source marking, click anchor/target ownership and capture policy. Actual Overwatch delay, BF1942 jumps/limits and Dock/menu behavior **pending hands-on game validation**. Mapped-event routing is not physical mouse seizure. |
| Application selection/streaming | Implemented/tested direct bundle and exact selected-wrapper rules. Native/Wine/streaming event consumption, protected processes and multi-display acceptance pending. |
| Passthrough/hybrid/selective | Implemented/tested all-primary-input presets and selective stick/trigger/gyro/touch/tilt routes alongside button routes. Legacy presets/data retained. No global macOS suppression, native Wine gyro/tilt delivery, or true virtual device identity. |
| Live editing | Implemented/tested immediate pending runtime overlays, 250 ms disk debounce, canonical own-source scopes including launcher inheritance, flushing on close/quit and structural actions. Numeric tuning and simple Pad/Mouse/Scroll/Off stick output changes plus compatible gyro output changes preserve unrelated state. Key/direction/flick, layer-config presence, mixed/unsupported edits still rebuild safely; complete state-preserving snapshots and measured playing/editor latency pending. |
| Toggles/layers/sequences/cleanup | Implemented/tested source ownership of latches, macro/pulse/timer/menu cleanup, partial additional-device removal/replacement and logical-main removal. Timer-capacity exhaustion releases sequence-held outputs and never emits an unreleaseable pulse. Full release cancels without selecting radial-menu actions or firing pending virtual taps. Actual system hotkeys/lifecycle/hardware tests pending. |
| Steam/original Steam Controller/wider devices | Diagnostics implemented. Pro Controller GUI motion callback receipt verified alongside Steam/installed Nokcandu; **nonzero rotation/output not verified**. Original Steam Controller modes, duplicate-free streaming coexistence and broader hardware matrix pending unavailable devices. |
| Virtual controller | Research completed to present feasibility boundary; implementation blocked on authorized signing/deployment and successful target recognition spike. No unsupported backend shipped. |
| Standalone/settings/notifications | Implemented; build and engine checks passed. Manual UI/notification/no-game relaunch checks pending. Built-in window-local input test added for user verification. |
| Experimental head motion/multiple sources | Transform/source-composition tests passed, session opt-in capability path implemented. Audio/headphone hardware testing and persistent independently routed main-device identities pending. |
| Test delivery | [Testing guide](../controller-overhaul-testing.md) covers staged app, UI paths, per-feature procedures, migration and Undo. Packaging result below. No installation or system permission changes. |

### Confirmed shared defects and fixes

* Toggle, layer, gyro, pulse and macro outputs now retain their originating input. Removing an additional-device slot releases that slot's actions without releasing unrelated main holds; replacing a slot identity also releases the old owner. Disconnect cleanup closes menus without choosing an action. `pe_release_main` clears primary-only state while preserving additional-device slots. Main GC devices still compose a logical group; this does not provide persistent independent per-controller routing.
* Full release previously could invoke actions while unwinding layers/virtual inputs. A cleanup guard blocks new downs/pulses, neutralizes positions and clears physical/press/timer state. Capacity tests fill the timer queue: pulse allocation fails without pressing, and a sequence unable to schedule a wait releases its held outputs instead of stranding them. An initial test used tap-only syntax, which intentionally compiles to immediate press; corrected to a genuine tap-plus-hold timer case.
* Own-profile saves now validate existing JSON and preserve first-new-feature bytes just like the shared library. A malformed existing library/own profile is rejected rather than replaced with an empty/default library. Own edit overlay identity uses canonical contents path, including inherited launcher source, instead of profile ID/display name.
* Map writes no longer recursively delete an unexpected directory. Checked atomic writes reject direct symbolic links/nonregular map paths and propagate failures. Refresh attempts the other environments too, then reports partial update explicitly. Saved profile settings and successful maps remain saved; no destructive rollback is attempted. UI creation/adoption/rename/duplicate paths now display save errors rather than selecting a nonexistent profile and announcing success.
* The simple live-output transition path preserves accelerators/raw positions and unrelated owners while changing between basic stick outputs; changed gyro output clears its old analog contribution. Structural key/direction/flick and incompatible changes continue to reject in-place mutation and use the existing replacement path.

### Privacy baseline resolution

The previous four privacy assertions/errors were reproduced from unchanged HEAD in a temporary baseline checkout under denied process inspection. They were not controller regressions. Temporary AppPrivacy test apps now register per-fixture closed process observations; teardown removes them. Production process enumeration/unknown-process safety remains unchanged. A new unreliable-observation test proves unknown still blocks unsafe preparation and retains microphone metadata. The real-process-enumeration test explicitly skips when enumeration is unavailable, while deterministic process-state safety tests still run. Historical failure counts above remain historical, not current status.

Final broad controller/profile/privacy/process selection before adding the input-test UI: **131 tests, one environmental skip, zero failures**. The five AppPrivacy tests pass. Separate targeted transition, recovery/map-write and disconnect/timer tests passed. This is a selected regression suite, not a claim that every repository/E2E/game test ran.

### Actual hardware boundary

A subsequent temporary GUI probe fed the shared engine but never posted output events. It observed approximately 6,954 motion callbacks and zero engine mouse moves with an idle Pro Controller. User could not perform the requested rotation test. Thus callback receipt is verified, nonzero rotational data/transformation/output latency is not. The probe was closed normally with its explicit Quit menu and verified absent. No pairing/sensor activation/device-mode writes or profile changes. Earlier descriptions of this as proven gyro movement are superseded by **motion callback receipt**.

### Migration, testing and Undo

All behavior remains central in Core/shared C/app/helper paths, no per-game workaround or launcher overwrite. Own and shared `.pre-controller-v2` backups are first-write/idempotent recovery copies. Existing fields/presets/macro timing remain compatible; new routing fields require the matching managed helper. Manual launcher ownership protections remain in existing shared update paths. No real library/profile/settings/game files were edited during automated checks. Undo procedures are in the testing guide; preserve later edits before restoring backups.

The new Help → Controller Input Test observes NSEvents only for its own window, returns them unchanged, records no characters and installs no global event tap. Its test area accepts ordinary keys without typing/beeping. Counters/last event are displayed at 10 Hz independently of receipt; marker/source PID identifies app-generated events. It proves native test-window receipt only and does not certify target games or system shortcut handling. Removing the view removes its local monitor. Packaging uses an explicit opt-in SwiftPM manifest-sandbox override for this restricted command environment and an explicit ad-hoc signing choice; it does not change OS permissions/keychain state.

Added the [connection-specific capability matrix](../controller-capabilities.md), including original Steam Controller USB/receiver/Bluetooth, existing Pro callback evidence, wider controllers, headphones and output target gates. Unknown rows are deliberately unverified rather than advertised support.

Native isolated UI verification used the actual `PadInputTest` source with only its actual Core event-source helper in a temporary preview app, avoiding full library startup/maintenance. Observed key down/up code 0, click down/up counters, layout and successful counter reset; ordinary Cmd-Q closed it and the app inventory then confirmed absence. These were computer-control events, not physical-controller-generated output. No user app terminated or profile/permission modified.

### Packaged test build result

Built `/Users/seth/nokcandu/build/Nokcandu.app` in release configuration with the updated universal arm64/x86_64 shared helper, existing Wine 10/11 Mac modules and verified native-IPX build artifacts. Deep strict codesign verification and Info.plist lint passed. The packaged executable UUID matches the release product, and the executable contains the new Controller Input Test UI. Signature changes the executable bytes as expected; a byte-for-byte comparison with the unsigned build product is not a meaningful integrity test after signing. The installed `~/Applications/Nokcandu.app` was not replaced or relaunched. The complete staged app was not launched against the user's library in this session; only the isolated input-window preview was run.

Final regression selection after the UI addition: **131 tests executed, one environment-dependent process-enumeration skip, zero failures**. `git diff --check` and shell syntax validation passed. This does not certify the full repository/E2E matrix. The test guide is ready with feature paths, safe starting conditions and explicit remaining acceptance gates.

Reproduction of packaging in this restricted environment required temporary compiler/module caches, `NOKCANDU_SWIFTPM_DISABLE_SANDBOX=1`, `NOKCANDU_SWIFTPM_SCRATCH_PATH=/tmp/nokcandu-controller-release`, `NOKCANDU_SWIFTPM_BUILD_SYSTEM=native`, `NOKCANDU_SIGN_IDENTITY=-`, `TMPDIR=/tmp`, and Zig local/global caches under `/tmp`. Default build behavior is unchanged. The first default-engine release attempt linked successfully but failed updating an existing dSYM with Operation not permitted; a clean temporary scratch/native build succeeded. Dependencies were downloaded from the existing recipe's official Zig/cabextract sources and verified against its pinned SHA-256 values before extraction/building; no global tool installation or keychain unlock. Initial offline download and default Zig cache writes failed; explicit temporary cache paths solved this. Do not work around these issues by changing process/privacy permissions.

Existing OpenGL deprecation warnings remain. `iconutil` rejected the generated iconset in this environment, which the existing build treats as a nonfatal warning; the staged app may display a generic icon. This does not invalidate its signature or executable/helper tests. No icon-artwork change was attempted as part of the controller overhaul. This remains a packaging limitation, not a controller fix.

The staged app is ad-hoc signed, so existing Accessibility authorization may not carry over. No permission was granted automatically. Do not interpret the build as installed, fully game-tested or the entire specification completed. Remaining software limitations include complete structural state-preserving snapshots, stable independently routed primary-device identities and measured input/editor performance. Remaining hardware/target gates are listed above and in the capability matrix.

## Unrelated running actions during editing

**Implemented/tested:** binding-only updates now preserve running macros, pending tap-release pulses, simultaneous-pair deadlines/active chords and radial menus when their owning bindings/partners are unchanged. The previous blanket refusal caused unnecessary engine replacement and unrelated release. Ownership already tracked by the engine now gates acceptance precisely. Changing a running macro/pulse/menu owner or simultaneous pair still rejects nonmutatingly for the existing safe replacement path; full structural snapshots remain pending. No profile schema/migration change.

Targeted live/cleanup/macro selection: 24 tests passed. New tests verify original macro/pulse deadlines, use of a newly edited unrelated binding, pending-to-active simultaneous pair continuity and nonmutating rejection for affected owners/peers. Initial new simultaneous tests used invalid fixture syntax (`simwith`); corrected to the engine's existing `sim`/`simout` grammar before acceptance. Actual playing/editor latency remains unmeasured. Applies to the shared runtime/preview/Wine reload API; Undo app/helper together. Updated test package will be rebuilt after this continuation's next changes.

### Replacing latched mode bindings

**Implemented/tested:** a changed layer-toggle or gyro-toggle binding now clears only its own persistent mode latch, even if its physical button was already released. The previous update released captured press outputs but left these persistent flags active indefinitely. Reproduced before the fix with three failed assertions; targeted live/cleanup/toggle/device selection afterward: 43 tests passed. Tests also prove another held key retains its captured layer output and unrelated latches survive edits. Layer configuration/output is reapplied after the binding table replacement. No schema/migration; shared app/helper API and corresponding rollback. Actual UI/hardware mode switching remains a manual gate.

## Directional key updates, visible Toggle behavior and timing diagnostics

### Progress checklist update

* **Implemented/tested:** key-stick output/key-code changes now use compatible live updates, releasing old held direction keys with their old codes before installing/recomputing the new mapping. Unrelated button/latch owners remain. Tests cover key replacement, mouse-to-keys using current position, overlapping same-key reference counts, and full cleanup. Flick/direction structural changes, mixed edits and layer-configuration-presence changes still rebuild. Invalid directional key codes are ignored rather than indexing outside key output storage.
* **Implemented/tested:** replaced the hidden-only toggle workflow with a visible **Toggle** choice alongside While held / Tap-Hold in the button inspector. Explains exactly “press once to keep held, press again to release.” Output choices are limited to holdable keys/mouse/controller buttons/triggers. Explicit optional `togglePress` metadata retains this selection even before an output is chosen, and compiles to existing/new persistent-output tokens. Switching to While held converts the outputs back. Old explicit key/mouse toggle tokens remain recognized; mixed existing bindings keep their mixed semantics until explicitly changed. Repeat is unavailable for Toggle and compilation suppresses repeat for uniform toggle bindings. Unsupported imported toggle outputs compile to Nothing, never accidental native passthrough.
* **Implemented/tested:** persistent controller-button and trigger output tokens (`padtoggle`, `trigtoggle`) use the same reference-counted ownership model as key/mouse toggles. Physical release does not end the latch; second press does. Duplicate down reports do not flip twice. Additional-device removal and changed-owner edits clear only that source's controller latches. Full cleanup clears all new latches; it now also resets the gyro-toggle flag to its configured default rather than carrying activation through a release/reconnect.
* **Implemented/tested:** optional timing aggregates in Controller diagnostics show mean/max local controller/motion/tick/profile-resolution handling and timer intervals, with reset. No individual event data is retained, and disabled diagnostics avoid timestamp/statistics work. A callback is counted before checking whether a mapping engine exists, so mapping-off no longer misrepresents actual receipt as missing hardware. Separate nonzero-rotation counts distinguish idle motion callbacks from rotational samples; neither proves deliberate movement or game acceptance.
* **Pending:** actual controller-generated toggle/system-shortcut/capture/game acceptance. Existing native Mac physical-controller visibility remains; toggled controller outputs are only the existing Wine route, not synthesized native devices. Runtime timing excludes queue delay before handler entry and screen/game response; end-to-end performance gate remains open.

### Verification and user feedback

The user reported no visible way to toggle and clarified the intended latch behavior. The running installed copy remains unchanged; its absence of development UI is expected. The development editor previously exposed only nested “Toggle Held Key/Mouse Button” output menus. Both discoverability and controller-output coverage were incomplete, so fixed centrally rather than just providing menu directions.

Targeted new toggle/model/live tests: 42 passed. Broader selected regression after the new timing implementation: **155 tests, one environmental skip, zero failures**. New cases exercise key/mouse/pad/trigger compile/round-trip, second-press release, duplicate reports, overlapping holds, partial disconnect, changed-owner cleanup, default gyro restoration and first-write backup for toggle metadata. Statistics tests reject invalid clock values and verify count/mean/max/threshold accounting. Subsequent small recorder/accessibility follow-up is verified below.

An isolated preview using the actual BindingEditor/OutputsEditor/OutputMenu/FlowRow sources and linked current Core/C objects verified the real UI: selected Toggle on a Q output, observed compiled `keytoggle:12`; added controller B from the limited menu, observed `padtoggle:b`; switched to While held, observed `key:12,pad:b`. Screenshot showed the visible explanation and selected Toggle state. No real profile/library/settings read or saved by the harness. Ordinary Cmd-Q closed it; app inventory confirmed absence. This is UI/compilation evidence, not actual controller output in a game.

The preview exposed an accessibility grouping limitation in the new Toggle branch: visible output controls were merged into explanatory text in AX. Added explicit containment to preserve child controls. Also inspected the output recorder's lifetime: its local event monitor previously lacked disappearance cleanup, so closing/changing the editor while recording could leave interception alive. It now cancels/removes that monitor on disappearance; Escape cancels recording, and the button/tooltip explicitly say Record/Escape (Escape itself remains selectable in the key menu). No global event interception or new permissions.

### Performance evidence boundary

Added a reproducible offline C engine benchmark with counting-only sinks, no OS event injection, I/O or real-time sleep. One initial optimized run: 100,000 simulated gyro+tick calls, mean 0.060 microseconds/p95 1/max 42; 1,000 compatible binding updates mean 39.746 microseconds/p95 47/max 97; destroy/create comparison mean 6.114 microseconds/p95 7/max 23. These single-session microbenchmarks have clock quantization/noise and no hardware/UI/output backend; they do not prove player-visible latency improvement. Compatible updates preserve state at a modest CPU cost versus rebuilding; do not market them as faster parsing. The actual playing/editor/disk-write baseline is still pending. The diagnostic 4 ms work and 8 ms interval thresholds are observation markers, not agreed latency guarantees.

### Migration, scope and Undo

New toggle metadata and tokens participate in the existing one-time `.pre-controller-v2` backup for both shared and own profiles. Old absent fields/presets remain unchanged. The compiled helper hash includes Core engine files, so the staged app packages the new shared behavior through the existing managed helper update/restart path. App/helper rollback must be coordinated; older installed helpers cannot be assumed to understand new tokens. No manually edited launcher, game content/save, installed app, system permission or real user profile was changed here. Duplicate/export before manual testing and use the documented backup restore process if reverting new-feature saves.

### Recorder/accessibility follow-up and final checks

The explicit Toggle container fixed the AX grouping problem: Remove/Add/Record controls were individually present in the subsequent actual preview tree. The recorder's Escape integration comparison was **confounded**: starting recording alone showed the correct waiting state, but the next automated keyboard action produced a mouse-click output before Escape could act. This does not isolate a starting-click bug; commentary attributing it to the start click was premature. A next-runloop monitor-install trial did not resolve that comparison and was removed. Avoid repeatedly treating automation targeting/focus events as physical-user recording evidence.

Moved recorder decisions into `PadOutputRecorder`, separate from event monitoring. Deterministic tests verify Escape yields cancellation with no output and clears modifiers, session reset, modifier-before-key ordering, valid extra mouse buttons, invalid/NaN scroll rejection and the same key-to-toggle conversion used by the menu. Existing UI still owns the window-local monitor and removes it on disappearance; no asynchronous installation race/heuristic delay was retained. Physical Escape integration and monitor-close integration remain manual gates. The temporary preview was closed normally and its absence verified.

Final selected regression: **159 tests, one process-enumeration environment skip, zero failures**. Sanitized (AddressSanitizer + UndefinedBehaviorSanitizer) offline engine benchmark completed successfully with no reported errors; this smoke run exercises synthetic gyro/tick and repeated compatible/rebuild updates, not every toggle/device path or real OS output. Full repository/E2E and hardware acceptance remain separate. Test package rebuilt below after final source changes.

### Updated package ready

Rebuilt `/Users/seth/nokcandu/build/Nokcandu.app` after the final recorder/Core/UI changes. Deep strict signature verification and plist lint passed; packaged/release executable UUIDs match. The packaged executable contains the visible Toggle explanation and new rotation diagnostics, and the packaged helper fingerprint exactly matches the current shared C/helper sources. Helper remains universal x86_64/arm64. Existing iconutil/OpenGL warnings are unchanged. Final source whitespace and build-script syntax checks passed. Installed app, permissions, library, real profiles and games remain unchanged; latest test guide directs users to quit the installed copy and open the staged path explicitly. The full staged app has not been launched against the user's library; real controller/game acceptance remains pending, not completed by these checks.

## User-authorized installation and actual editor verification

The user explicitly authorized freely installing builds to make the work usable in their normal Nokcandu. Quit the old app normally and verified it absent; installed the verified staged build into `~/Applications/Nokcandu.app` through the existing app-only recovery installer. The helper exited successfully, installed executable bytes match the verified staged executable, deep strict signature verification passed, and the shared controller-library hash was unchanged immediately after replacement. Verified the newest recovery entry includes both archived app and executable restore command. No manual launcher/game/save replacement was performed.

Reopened the exact installed path. The actual Overwatch profile inspector now contains the visible While held / Toggle / Tap-Hold choices. The user began editing during inspection; subsequent AX showed Toggle selected with Toggle Space. Did not overwrite the user's new choice or claim later profile bytes remained unchanged. This supersedes earlier “not installed” status; historical build evidence remains historical. Updated the testing guide to point to the normal installed app.

The updated installed app reports Needs Accessibility permission. Both old and new apps are ad-hoc signed, and no stable signing identity is available in this command context. The build change invalidated effective authorization. Requested specific permission to restore Nokcandu's existing keyboard/pointer control rather than granting security-sensitive access from the general install authorization. Permission restoration is pending the user's response; UI visibility is verified, mapped input is not yet certified functional. No system permission changes made at this point.

## Toggle output labels on the controller picture

The user reported the picture showed only “Key toggle,” hiding its actual target. The inspector already used full output titles, but `shortLabel` replaced every toggle with a generic category. Changed the shared picture-label path for key/mouse/controller/trigger toggles to use the existing actual output title (for example Toggle Space, Toggle Left click, Toggle B). It now reads compiled-effective press outputs too, covering explicit toggle behavior metadata with regular stored output values. Compact picture labels may shrink to 70% and offer their full text on hover; accessibility names include the full target. No profile data/schema or engine behavior change. Existing toggle/live regression selection and installed UI verification recorded below. App-only rollback restores old labels; no helper/content migration required.

Accessibility restoration was explicitly authorized by the user. On this macOS build the relevant privacy pane is titled Device Control and Data Access. It already lists Nokcandu switched on, while the updated app reports untrusted; this is stale effective authorization after ad-hoc replacement, not a missing profile. Restore only Nokcandu's existing grant after installing the label update, leaving other app grants untouched.

### Label installation and effective permission restored

42 targeted toggle/live tests passed; app product compiled, package rebuilt and deep signature verified. Installed through the authorized app-only recovery helper; installed executable bytes match the verified package. The actual installed Overwatch editor now shows **A: Toggle Space** in AX and visibly beneath A in the controller picture. No profile mapping was changed by this label correction.

With the user's specific Accessibility authorization, refreshing the old on/off switch alone did not restore effective trust. macOS required authentication; the user completed that system dialog themselves, no password supplied to the assistant. Then removed only Nokcandu's stale privacy entry, re-added the exact `~/Applications/Nokcandu.app` through the native application picker, and confirmed its switch on. Reopened the installed app: its status now reads **Everywhere: Overwatch**, and the Needs Accessibility permission warning/Allow button are absent. This verifies effective AX authorization and the corrected label, not actual controller movement/game acceptance. Other app privacy switches were left untouched. No direct privacy database edits, broad reset, signing bypass or new permission scope. System Settings is left on the relevant permission page; Nokcandu is returned to the user's Overwatch editor.

This supersedes the earlier pending permission-restoration status. Ad-hoc builds may require this authorized refresh again after future updates; stable signing remains separate deployment work. The app's Test area still says to connect a controller, so this continuation makes no hardware-specific functionality claim.


## Native Wine enumeration follow-up — verified November 10

**Implemented/tested:** explicit native mode now outranks automatic shared-profile
adaptation; offline routing follows CurrentControlSet links; Windows tools apply
saved routing before the first process; the shared helper restricts SDL function
interception to Wine-driver callers. The unscoped hook was confirmed recursively
intercepting SDL internal lookups, independently of profile state. The fixed
installed Steam environment now enumerates connected Pro Controller 057e:2009 in
DirectInput and visibly lists it in its actual Windows controller panel. The
isolated mapped/Xbox route also enumerates XInput. **Pending:** button/gyro/report
and game acceptance, original Steam Controller transport support, and other
hardware matrix items; do not read this as complete overhaul acceptance.

**Implemented/tested:** stable existing signer reuse plus local install continuity
guard; actual changed-code updates retain Accessibility. **Implemented/tested:**
section-first search and separate Games/Profiles footer, actual installed UI
verified. **Diagnosed/pending:** duplicate external SSD aliases, preserved without
cleanup. Detailed comparisons, regression test, delivery/migration/Undo and current
checklist are in [the follow-up investigation](signing-routing-sidebar-drives-2026-11-10.md).


## User testing preparation and profile headphone source

**Implemented/tested, packaged; installed UI acceptance pending unlock:** headphone
head tracking is now a profile-selected Add Device source with saved tuning and
inherited membership/disable/removal, replacing the global session tuning design.
Existing profiles remain opted out. Runtime resolves the source before comparing
compiled engine text; explicit gyro-off holds pause it. Controller Input Test now
shows observed held keys/buttons, bounded timed transitions and local Copy Test
Report; focus loss marks state incomplete. Five profile-head configuration/storage
tests and four observation tests cover these additions; the expanded selection is
185 passing tests, plus nine signing and the actual-helper regression. No actual
headphone/audio acceptance claim. The Mac locked before normal app replacement;
new build is staged, previous native-Wine fix remains installed. See the
[follow-up checklist](signing-routing-sidebar-drives-2026-11-10.md#preparation-for-user-testing-held-output-receipt-and-profile-headphone-source).


The user subsequently unlocked the Mac; the profile-headphone/test-window build
is now installed with the existing signing identity. Actual installed UI verified
Add Device/headphone chip/inspector, disable and removal in an unassigned temporary
profile (then deleted). Input Test verified ordinary Space/mouse down-up receipt,
ordered times, focus-loss invalidation and Reset. No headset permission or active
profile change was made. The tester is open/reset for tonight. This supersedes
installation-pending status in the preceding preparation note; hardware acceptance
remains pending.


## Original Steam Controller receiver-off stage

User clarified that only the original dongle is connected; controller is off.
**Implemented/tested:** receiver-aware status, passive host-property inventory and
Windows present-HID probe. **Research feasibility tested, not shipped:** strict
opt-in original Valve vendor-interface exception exposes four receiver slots to
Windows in a temporary engine; normal/default-off expose zero. Four interfaces
are not four active controllers. **Pending controller-on:** Windows Steam device
recognition/feature transfers, full profile reader with both pads/grips/gyro,
ownership/coexistence and games. No pairing/firmware/mode changes or installed
engine replacement. [Detailed checklist and Undo](steam-controller-2015-2026-11-10.md).


## User field-test follow-up

- **Implemented/tested/installed:** headphone per-profile Always/physical-hold/layer
  activation, additive to controller gyro; inactive transition recentering and UI.
- **Implemented/build tested/installed, game retest pending:** shared Wine 10/11
  virtual/Retina coordinate bridge and captured Wine relative-socket delivery.
  User identifies Overwatch for virtual aim/click offset; BF1942 separately hits
  the right cursor boundary. Neither game is yet declared fixed in play.
- **Implemented/tested/installed:** exact USB Pro descriptor correction, full-SDL
  build, hash-gated idle migration with original recovery and persistent Undo.
  Repeat actual native Windows receipt: 375 samples/zero false button transitions;
  all physical controls, WGI, Steam and game use still pending. 200 related tests pass.
- **User verified root cause:** mystery gyro with Nokcandu off came from Steam Input.
- **Pending:** Trackmania route/output comparison, original Steam Controller live
  feature/report support and full editor, optional Home system-gesture preference.

[Detailed evidence, current checklist, limits and Undo](controller-field-tests-2026-11-10.md).

Final installed shared Steam receipt confirms 18 buttons/four axes, 375 successful
samples, zero false transitions and zero held buttons. Exact stock-driver original
and final source/installed hashes verified. The final descriptor excludes six
reserved bits; early 24-bit declarations are superseded. Physical action/game
acceptance remains pending. See field-test notes for the full evidence and Undo.


## November 11 expanded field tests

[Eleven-page report intake and current checklist](controller-field-tests-2026-11-11.md). User confirms Overwatch virtual-screen aim and BF aiming edge improved; click jumps, scaling and sensor reliability remain unresolved. Same-profile focus calibration retention is implemented and engine-tested; signed build installed and UI verified; physical acceptance pending. Wired Steam native Windows recognition, wireless input, trackball, sensor activation/ownership and haptics remain pending. Other report requirements are tracked individually; overall overhaul is incomplete.


## BF2 deployment-menu follow-up and shared settings durability

- **Implemented / software tested / installed:** opt-in BF2 deployment-menu recovery using the option from upstream DXVK PR 3797; normal BF2Hub route retained, per-component Undo.
- **Implemented / tested / installed:** current-settings/receipt reconciliation in launcher/helper maintenance and component preservation in queued custom settings. Actual post-restart/post-Play BF2 flag and generated export verified retained.
- **User test, attribution not yet established:** Dalian Plant menu appeared in one test; Wake Island, repeat loads and focus-return with final activation pending. Do not mark the whole menu issue resolved.
- **Pending:** controller click coordinates, duplicate/native routing, full wired/wireless Steam controller behavior and remaining November 11 report items. No claim of overhaul completion.

[Detailed sources, failed first activation, migration, tests and Undo](bf2-deployment-menu-2026-11-11.md).


### Further November 11 increments

- **Implemented / engine tested:** mouse/gyro-picked radial menus and automatic action titles with explicit-title preservation. Physical-input/UI acceptance remains pending until final package verification.
- **Implemented / actual renderer probe tested:** BF2 recovery file transport, flag-only receipt upgrade and linked-parent path correction. Prior inline-only transport was not effective in the legacy Sikarugir renderer and is superseded.
- **User tested:** Wake Island and Dalian Plant deployment menus visible in subsequent runs; causation and repeated final-transport acceptance remain limited.
- **Investigating:** BF2 poor performance. Actual selected DXMT run used WineD3D/OpenGL; changed to appropriate newer D3D9 path for a controlled comparison. No measured performance fix yet.
- **Blocked on reproduction input:** BF1943 unfinished setup/original folder not found; filename-normalization theory unconfirmed.

Current final related automated suite: 273 tests, zero failures, two explicit optional skips. All remaining field report/controller requirements stay open as individually recorded.


Final full-suite verification for this increment: **589 tests, zero failures, 19 explicit optional integration skips; all privacy tests pass**. Mouse/gyro radial picker and title guidance observed in installed UI with no profile edits. BF2's final config transport is backed by an actual legacy-renderer initialization probe, and ordinary private settings saves centrally preserve installed component environment/DLL keys until explicit Undo. User menu checks were positive in Wake Island and Dalian Plant; newer D3D9 performance comparison and the remaining controller backlog are still pending.


## November 11 afternoon reprioritization

The user explicitly deferred BF2 performance and supplied a new eight-page priority report. Follow the [current priority checklist](controller-priorities-2026-11-11.md), starting with missing Pro/Xbox game input and duplicate controller identities. The last exact-source package must be verified/installed as part of the next controller update; prior successful builds/UI receipts do not establish that final install. No overall overhaul completion is claimed.

## November 11 session handoff

User reprioritized via the Top Priority Prompts PDF, then limited the final increment to independent original Steam Controller trackpad/trackball behavior and a handoff. Final installed build passed 605 tests (19 optional skips, zero failures). Right pad is set to Trackball mouse; left behavior remains independent. Mode takeover/restoration and a normal-typing user retest were verified. The overhaul remains incomplete; see [final handoff](controller-handoff-2026-11-11.md) and [current priority checklist](controller-priorities-2026-11-11.md). Do not resume from an older passive-reader or wrong-SDL conclusion.

### November 11 final pad increment

Installed per-pad trackball release correction, X/Y tuning, touch gyro, movement haptics and independent pulse-rate/spacing controls. User confirmed fling direction fixed, feedback on right pad and gyro only while touching. Added a global gyro-note switch and switched it off without changing layer/calibration notes. Final suite: 615 tests, zero failures, 19 optional integration skips. Broader overhaul remains incomplete; current scope, pending hardware/game checks, migration and Undo are in the [handoff](controller-handoff-2026-11-11.md).

November 11 follow-up: movement-matched pad haptics and Steam-specific diagram placement are implemented, tested and installed. Suite now 616 tests, zero failures/19 optional skips; installed UI verified, new feedback feel pending user acceptance. Existing haptic tuning retained. [Final handoff](controller-handoff-2026-11-11.md).


## 2026-11-11 receiver/UI follow-up

- Implemented/tested: original-controller wireless receiver profile source, remote identity recovery, bounded capture-loss recovery, edge-coast correction and optional pad steadiness. Full suite checkpoint: 628 tests, zero failures, 19 optional skips; privacy checks passed. Hardware and current typing limitations: [wireless investigation](steam-wireless-profiles-2026-11-11.md).
- Implemented/tested: consistent trailing settings alignment, per-profile controller Labels and Steam schematic/caption positioning. [UI evidence and Undo](settings-profile-labels-2026-11-11.md).
- Pending: intermittent doubled physical typing, final restored-haptics comparison, broader receiver/cable reconnect and game acceptance. Native Windows Steam receiver passthrough is unverified. This is not completion of the entire overhaul.

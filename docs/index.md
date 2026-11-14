# Nokcandu documentation

The project README introduces the app. This folder keeps the implementation knowledge, troubleshooting evidence, and development notes that need to survive individual chats.

| Document | What belongs there |
| --- | --- |
| [Streams](streams.md) | The game-streaming client ported from VoidLink/Moonlight: licence change, layout, pairing and stream flow, profile passthrough, what is verified and what is not ported yet. |
| [Idle CPU, space management and moves](investigations/space-efficiency-moves-2026-11-04.md) | Measured idle-CPU causes, clone-aware space accounting, restore-point/roll-back/log limits, moved-game install records, split app/files moves, launcher moves and APFS games volumes. |
| [Development handoff — November 4, 2026](handoffs/development-handoff-2026-11-04.md) | Released work, exact verification, confirmed open issues, prioritized polish, code map and safe continuation checklist. |
| [Release 0.12.4 verification](investigations/release-0.12.4-2026-11-04.md) | Profile/component release scope, migration, known issues and package verification. |
| [Fullscreen Spaces input investigation](investigations/fullscreen-space-input-2026-11-03.md) | Deferred BF2 virtual-screen input loss, failed candidate, safe cleanup and evidence needed before resuming. |
| [Profile validator parity](investigations/profile-validator-parity-2026-11-03.md) | Corrected missing software-audio fix ID, explicit invalid reasons, revalidation and app/catalog CI parity. |
| [Launcher DX8 eligibility and icon editing](investigations/launcher-dx8-and-icon-editing-2026-11-03.md) | Mixed-architecture launcher handling, independent EXE icon selection, Undo and separate unresolved BF1942/BF2 reports. |
| [Installer destination mismatch](investigations/installer-destination-2026-11-01.md) | Why GOG setup bypassed the prepared external folder; shared Inno destination handoff and copy fallback. |
| [Nonblocking installation](investigations/nonblocking-installation-2026-11-01.md) | Separate installation window, retained session, library access and existing Windows-setup preservation. |
| [Graphics detection investigation](investigations/graphics-detection-2026-11-01.md) | Bootstrap launchers, delay imports, unknown API defaults, installed Rocket League regression and review-only migration. |
| [LAN discovery investigation](investigations/lan-discovery-2026-11-01.md) | Battlefield/GameSpy query evidence and reusable diagnostic; LAN browsing restored after the user disabled the Windows host’s virtual Ethernet adapter. |
| [BF1942 Internet browser](investigations/bf1942-internet-browser-2026-11-01.md) | Verified obsolete master hostname, fingerprinted managed-copy correction, safe migration and combined Undo; user confirmed Internet servers appear after the two-slot correction. |
| [Mac native IPX investigation](investigations/native-ipx-mac-2026-11-01.md) | Final managed ROM2 discovery/joining confirmed in both directions; earlier gameplay confirmation, session-based permissions, adapter migration, profile/Undo behavior and VM NAT/bridge troubleshooting. |
| [Shared IPX and ROM2 investigation](investigations/ipx-rom2-networking-2026-11-01.md) | Optional shared IPX component, native engine/probe evidence, TCP/IP comparison, profile service parity and later multiplayer test. |
| [Engineering learnings](engineering-learnings.md) | Confirmed lessons, the scope of each fix, evidence, unresolved issues, and rules for future changes. Start here. |
| [Compatibility fixes](compatibility-fixes.md) | Component IDs, implementation details, sources, ownership/Undo, migrations, and game/launcher-specific findings. |
| [EA gameplay audio investigation](investigations/ea-gameplay-audio-2026-10-28.md) | The complete dated trial-and-error record for BC2/DAO audio, failed comparisons, restored settings, and remaining questions. |
| [Wine 11 launcher surfaces](investigations/wine11-launcher-surfaces-2026-10-30.md) | Metal surface/presentation and foreign-child hosting fixes; Steam browser-only rendering policy, failed controls and verification limits. |
| [Chrono Trigger media investigation](investigations/chrono-trigger-media-2026-10-29.md) | Confirmed shared GStreamer library-path correction, startup evidence, migration and selected-game restart behavior. |
| [Resizable game-window implementation plan](resizable-game-window-plan.md) | Milestones, architecture, input/scaling, renderer coverage, profiles, launchers, rollback and release gates. Planned work. |
| [Resizable fullscreen-window feasibility](investigations/windowed-fullscreen-feasibility-2026-10-29.md) | Why Wine’s virtual desktop is disabled on the Mac driver, and the requirements for a shared scaling/input backend. Historical research; the driver backend was subsequently implemented. |
| [Launcher notes](launcher-notes.md) | Optional compatibility fixes, display controls, complete profiles and storage (moved from the README). |
| [Development](DEVELOPMENT.md) | Build/release instructions and the historical implementation milestones. |
| [Gaming roadmap](gaming-roadmap.md) | Dated proposals to evaluate; these are not a list of verified fixes or a guarantee of current implementation status. |
| [Release notes](../release-notes/) | User-facing changes grouped by released version. |

## Recording new findings

Update these docs in the same change as the implementation:

1. State the symptom, affected versions/hardware, and how it was reproduced.
2. Separate a confirmed cause from a hypothesis or correlated log message.
3. Record the successful change **and unsuccessful comparisons** worth avoiding later.
4. Identify its scope: shared infrastructure, launcher-specific, game-specific, or one verified binary build.
5. Link the implementation and tests. Say whether verification covered startup, the visible menu, gameplay, sound, input, or restart/update recovery.
6. Explain fresh-install behavior, safe migration, backup/Undo, and unresolved limits.
7. Update the current status when new evidence supersedes a result. Keep detailed dated investigations as historical snapshots.

Keep credentials, account identifiers, raw session logs, copyrighted game/runtime binaries, and machine-specific backup files out of the repository. Use portable paths and record checked hashes instead. A temporary log filename is evidence provenance, not a durable backup.

- [External game launch and storage accounting](investigations/external-game-launch-storage-2026-11-02.md) — native app privacy identity, visible startup errors, external-drive runtime accounting and safe migration/Undo.

- [Clean-runner CI test dependencies](investigations/ci-clean-tests-2026-11-02.md) — remove accidental prebuilt-runtime dependencies from adapter and native-entry unit tests.

- [Microphone-off enforcement](investigations/microphone-off-enforcement-2026-11-02.md) — shared bootstrap policy, capture boundary, launcher separation and tests without recording audio.
- [Recipe storage and user settings](investigations/recipe-storage-settings-2026-11-02.md) — recipe content moves, editable defaults, launcher preservation, profiles and Undo.

- [Microphone permission during playback](investigations/microphone-playback-permission-2026-11-02.md) — fresh-identity reproduction, Off/On eligibility, legacy Core Audio queries, shared clients and Undo.
- [Live microphone control and raw mouse permission explanation](investigations/live-microphone-switch-2026-11-02.md) — capture stop/resume without a Wine restart, cached endpoint discovery, privacy boundaries and migration.
- [Shared microphone routing, UI polling and helper Repair](investigations/shared-microphone-routing-ui-repair-2026-11-02.md) — Wine argv mutation, frozen status polling, host-level helper restoration and regression coverage.
- [BF2Hub account connectivity investigation](investigations/bf2hub-account-connectivity-2026-11-02.md) — confirmed TCP reachability and official module checks, failed tracing comparisons, restored startup and unresolved login.
- [Wine server closed-socket readiness](investigations/wineserver-closed-socket-readiness-2026-11-02.md) — synthetic reproduction, server-only normalization, genuine-error/OOB regression coverage and activation/Undo.

- [Shared helper activation, status failure and Repair hardening](investigations/helper-activation-repair-hardening-2026-11-02.md)

- [Storage settings performance and on-demand measurements](investigations/storage-browser-performance-2026-11-03.md)

- [Storage game-location accounting across drives and launchers](investigations/storage-game-location-accounting-2026-11-03.md)

- [Automatic installer-media drives](investigations/automatic-installer-drives-2026-11-03.md) — stale image mappings, guarded shared cleanup, existing-installation authorization and Undo.

- [Automatic store-game discovery](investigations/automatic-store-game-discovery-2026-11-03.md) — background installation detection, idempotent shortcuts, preserved settings/removal choices and installer completion callbacks.

- [Explicit Sikarugir Wine versions](investigations/wine-version-selection-2026-11-03.md) — game dropdowns, new-install defaults/overrides, safe resume/Repair behavior and exact rollback.

- [Save settings without forced restarts](investigations/deferred-game-settings-2026-11-03.md) — durable pending choices, idle-versus-active process evidence, direct app-icon preflight and safe retry/discard.

- [Nokcandu app-version rollback](investigations/app-version-rollback-2026-11-03.md) — verified local/remote app replacement, independent recovery, preserved user data and failure safety.

- [Release 0.12.3 verification](investigations/release-0.12.3-2026-11-03.md) — release gate evidence, packaged components, migration and recovery scope.

- [Wine 10 → 11 stale-wrapper upgrade failure](investigations/wine-upgrade-stale-wrapper-2026-11-03.md) — reproduced ntdll startup error, shared setup/identity correction and exact rollback coverage.

- [Microphone-Off prompt: 0.12.4 target](investigations/microphone-off-prompt-2026-11-03.md) — unresolved dialog regression, verified capture blocking, unsuccessful comparisons and release deferral.

- [Apply pending settings after exit](investigations/pending-settings-idle-2026-11-04.md) — automatic idle application, per-control indicators, shared-host safety and bounded failure retries.

- [CI monitor crash and refused-connection probe](investigations/ci-pending-monitor-and-refusal-2026-11-04.md) — runner/local differences, callback compatibility and synchronous versus asynchronous Winsock errors.

- [Shared-launcher game compatibility components](investigations/shared-launcher-compatibility-2026-11-04.md) — Steam/Battle.net/EA/Ubisoft program isolation, generic fix installation, profiles, recovery and Undo.

- [Controller overhaul implementation and progress](investigations/controller-overhaul-2026-11-10.md) — architecture, capability boundaries, incremental changes, test evidence, remaining hardware gates, migration and Undo.

- [Controller overhaul testing](controller-overhaul-testing.md) — staged app, in-app input test, feature checklist, game/hardware procedures and Undo.
- [Controller capabilities](controller-capabilities.md) — connection-specific evidence, unsupported output boundaries and hardware/virtual-device validation gates.
- [Signing, motion pause, routing and sidebar follow-up](investigations/signing-routing-sidebar-drives-2026-11-10.md) — permission identity, profile headphone sources, held-output tester, shared motion-off behavior, real Wine routing/enumeration fixes, layout issues and duplicate external-drive investigation.

- [Original Steam Controller receiver and Wine research](investigations/steam-controller-2015-2026-11-10.md) — receiver-off inventory, opt-in native vendor HID feasibility, profile-mapping gaps and controller-on acceptance gates.

- [Controller field-test follow-up](investigations/controller-field-tests-2026-11-10.md) — headphone hold/layer activation, Overwatch coordinate validation, BF1942 capture routing and reproduced Pro Controller false button transitions.

- [Wired Steam Controller and general headphone mappings (November 11)](investigations/steam-wired-head-mappings-2026-11-11.md)
- [November 11 field-test report](investigations/controller-field-tests-2026-11-11.md) — screenshot-backed regression checklist and follow-up validation.

- [BF2 missing deployment menu](investigations/bf2-deployment-menu-2026-11-11.md) — supported DXVK focus-loss workaround, opt-in component and acceptance limits.

- [Mouse/gyro radial menus](investigations/controller-mouse-menus-2026-11-11.md) — directional selection, action titles and cancellation/compatibility checks.

- [Afternoon controller priorities](investigations/controller-priorities-2026-11-11.md) — current user priority list, routing investigation and deferred BF2 handoff.

- [Controller handoff — November 11](investigations/controller-handoff-2026-11-11.md) — verified controller routing/takeover, independent trackball behavior, installation evidence and remaining priorities.

- [Steam Controller wireless profile source](investigations/steam-wireless-profiles-2026-11-11.md) — receiver slots, verified mode exchange and input receipt, connection safety, testing and Undo.

- [Settings alignment and per-profile controller labels](investigations/settings-profile-labels-2026-11-11.md) — shared control alignment, label persistence, migration and installed verification.

- [Controller click jump, Steam pad feel and library/editor polish](investigations/controller-click-jump-and-polish-2026-11-11.md) — why clicks moved the cursor (three causes), the Steam Controller's built-in button actions, the stale-pointer driver fix, pad smoothing/angle, categories and the responsive editor.

- [Handoff — November 13](investigations/handoff-2026-11-13.md) — the open Steam Controller trackpad jitter while moving (data, recorder, leads, constraints) and everything done since 0.12.18: streams, VBAN, emulated controllers, fed controllers, rumble, profile recovery, memory fix, verification status.

- [Steam pad jitter while moving](investigations/steam-pad-moving-jitter-2026-11-13.md) — haptics ruled out from the recording, filters compared (low-pass, line prediction, One Euro), the noise-proportional filter built, measured jitter and lag (confirmed by the user); then the Mac pointer's choppiness traced to two sources overwriting each other's moves (`PadPointerContinuity`), also confirmed.

- [Gyro quiet calibration](investigations/gyro-quiet-calibration-2026-11-13.md) — hand-held gyro recording, why the quick automatic measurement replaced good calibrations, the 5-second quiet rule and its trials, silent corrections, carry-over across engine rebuilds; awaiting confirmation.

- [Online play, priorities and shader stutter](investigations/online-play-and-shader-stutter-2026-11-12.md) — msync confirmed, a game's own store client no longer backgrounded, wineserver priority, what DXMT's shader cache can and can't do for Overwatch.


# Engineering learnings

Last reviewed: October 30, 2026. These findings come from Nokcandu development and troubleshooting on an Apple Silicon MacBook Air M4. A successful local test is evidence for that tested setup, not a promise that every game or launcher works.

Detailed implementation notes live in [compatibility-fixes.md](compatibility-fixes.md). Dated investigations retain the failed trials and configuration snapshots; this document summarizes the current conclusions.

## Confirmed shared lessons

| Lesson | Retained behavior | Evidence and implementation |
| --- | --- | --- |
| Extra DLL fixes must not replace graphics-backend rules. | Merge renderer defaults with component/user rules by DLL name; explicit per-DLL choices win. Apply to standalone and hosted launchers. | Tests execute generated shell exports for all six graphics modes and hosted games. [CustomGame.swift](../Sources/NokcanduCore/CustomGame.swift), [HostedSettings.swift](../Sources/NokcanduCore/HostedSettings.swift), [tests](../Tests/NokcanduCoreTests/RendererOverrideTests.swift). |
| Installation and the application started by setup have different lifetimes. | General EXE/MSI setup hands control back without waiting for a launcher to quit. Continue checks installed programs; program selection and self-check remain separate validation steps. | Reproduced by Ubisoft setup leaving its client open. Tests reject empty installations and verify no indefinite `/wait` handoff. [CustomInstall.swift](../Sources/NokcanduCore/CustomInstall.swift), [tests](../Tests/NokcanduCoreTests/InstallerHandoffTests.swift). |
| Descendants can retain installer output pipes after the original process exits. | Bound output, drain nonblocking, honor cancellation/timeouts, and stop waiting for EOF held by descendants. | EA/DLC setup exposed the hang. [Support.swift](../Sources/NokcanduCore/Support.swift). |
| Native ARM utilities must not load an Intel Wine helper. | Scope injection to Wine invocations; preserve child-process routing without exporting the helper globally to Python/shell utilities. | Zero Hour's native Python failed with an incompatible-architecture error; visible game startup recovered after the shared fix. [HelperPatch.swift](../Sources/NokcanduCore/HelperPatch.swift). |
| Browser workers and background services are not foreground games. | Exclude known service/browser/elevation workers from native game-window and input/display hooks. Keep the actual launcher and game eligible. | EA, Steam and Ubisoft worker roles have shared classification and regression coverage. [process roles](../Resources/rawmouse/windows-process-role.h), [tests](../Tests/NokcanduCoreTests/WindowsProcessRoleTests.swift). |
| A stopped Wine server does not necessarily mean every native child exited. | Check the selected environment's owned processes, wait for shutdown and supervisors, then apply settings/reopen. Explain the scope and unsaved-progress risk. Avoid global Wine kills. | An EA game survived its server. Fixture tests verify an owned orphan is stopped and unrelated processes survive. [WineTools.swift](../Sources/NokcanduCore/WineTools.swift). |
| Shared launchers need per-program settings and explicit routing. | Keep supported graphics, arguments, performance and mouse state in each game shortcut; resolve its host for Windows tools. A missing per-game raw-mouse flag means off. | Verified helper loading and per-program matching; settings/profile coverage. [HostedSettings.swift](../Sources/NokcanduCore/HostedSettings.swift), [RawMouse.swift](../Sources/NokcanduCore/RawMouse.swift). |
| The game's registered installation root can be much larger than its executable directory. | Count the registered root; distinguish app/runtime, external content, settings and shared space. Missing files and disconnected drives are different states. | DAO was counted as about 198 MB (`bin_ship`) instead of its full roughly 63 GB installation. [LauncherInstallation.swift](../Sources/NokcanduCore/LauncherInstallation.swift). |
| Removing a shortcut is different from removing an installation. | Offer app-only versus app-and-verified-game-files removal, show paths/drives, preserve shared roots and offline drives, use Trash, and filter genuinely stale launcher entries. | Shared removal fixtures cover path replacement, overlapping roots, offline drives and Trash failures. [GameRemoval.swift](../Sources/NokcanduCore/GameRemoval.swift), [tests](../Tests/NokcanduCoreTests/LauncherRemovalTests.swift). |
| Rollback data belongs to a specific engine. | Keep the original audio driver with its engine's rollback record; never apply another engine's saved driver as a buffer adjustment. | Tests cover present/missing baselines and exclude hosted shortcuts as engine owners. [Updates.swift](../Sources/NokcanduCore/Updates.swift). |
| Game-owned configuration evolves during normal use. | Manage allowlisted settings individually where supported, retain unrelated edits and preserve backups. Fingerprint generated launchers before migration; do not overwrite manual edits. | BF1942 resolution/mod troubleshooting and shared journal/profile tests. [ChangeJournal.swift](../Sources/NokcanduCore/ChangeJournal.swift). |

## Shared media loading and settings restart — October 29, 2026

Chrono Trigger's logo-then-black-screen failure was resolved in a controlled launch by including the bundled GStreamer library directory in Wine's library search path. Media Foundation had failed to create its parser before decoder selection, despite LAV already being installed. `WineEnvironment` now provides this directory centrally for fresh launchers, shared hosts, installers and tools. Recognized generated scripts migrate safely; Steam detects that its old running environment needs restarting. This is not evidence that the unresolved EA gameplay audio issue is fixed.

Apply and Restart now relaunches the selected game's standard launcher after a successful edit, so it starts both its host and the game. An edit failure recovers only the host. The full suite passed 182 tests with six optional skips; the signed build passed. The installed normal restart API check also passed; visual inspection of that relaunch stalled. See the [dated evidence and limits](investigations/chrono-trigger-media-2026-10-29.md).

### Follow-up: choose graphics from the engine, not just the main executable

Chrono Trigger's normal launch needed Compatibility as well as the media path fix. Its default Older 3D games mode failed to create the movie presentation surface; the direct diagnostic had not selected that renderer. The user confirmed the corrected normal Steam launch works. The OpenGL import resides in `libcocos2d.dll`, which the main executable imports. Shared detection now follows bounded, same-directory imported engine dependencies; install defaults and Recommended Settings use that evidence, while preserving saved choices and confirmed working modes. Unrelated DLLs, outside-directory symlinks and wrong-architecture dependencies cannot choose the mode. See the [follow-up evidence](investigations/chrono-trigger-media-2026-10-29.md#follow-up-normal-launch-black-screen-and-engine-detection).

## Wine 11 launcher surfaces — October 30, 2026

Foreign top-level swapchain support does not imply foreign child-window support. Modern browser
workers need both the Metal-surface API and a correctly positioned remote layer in the window-owning
process. The new Wine 11 driver supplies that path and frame-presentation notifications. A separate
process targeting a child HWND failed before the port and presented successfully after it.

A working launcher also depends on its browser renderer. Steam's software path stayed black; its
GPU browser rendered with DXMT isolated to browser workers while games retained Older 3D graphics.
Export cross-process capability before Windows process creation; changing Unix getenv in a native
constructor cannot retroactively change the inherited Windows environment block. Wine 10 retains
its prior defaults. Steam also persists its own GPU preference; launch flags alone do not override
an older saved off value. Synchronize that preference to Nokcandu's effective choice before startup.
The user confirmed the installed app renders after this alignment. Remote hosted layers also need
explicit participation in virtual-screen relayout: they are not NSView children. Fixed remote pixel
bounds plus transformed host targets corrected the stale resize/fullscreen picture; the user
confirmed both behaviors in installed Steam and EA. An already-running EA process needed its driver
refresh and restart before receiving the correction. Explicit GPU/software choices
are saved, and effective browser policy enters the restart identity. See the [dated trial record, provenance, migration and limits](investigations/wine11-launcher-surfaces-2026-10-30.md).

## Launcher-specific findings

### Ubisoft Connect — sign-in rendering verified

On the tested Wine 10/DXMT setup, Ubisoft's browser rendered its sign-in form when GPU work stayed in the main browser process. Ubisoft disables CEF launch switches internally, so simply adding `--in-process-gpu` was insufficient.

The `ubisoft-browser` component makes an exact-hash-checked compatibility edit to the tested 32-bit browser library, adds that switch, and enables DXMT cross-process support. The selected renderer's rules are preserved. The original file is backed up and Undo is supported; no browser sandbox or certificate checks are disabled. It is visible only for Ubisoft, can be saved/shared in profiles, and is applied by fresh dedicated Ubisoft setup with the shader compiler and DXMT selection.

The working result was observed both in the disposable comparison and the normal installed app. The alternate WineCX engine, disabling the GPU/software rendering, other graphics comparisons, and removing the native helper did not establish a working solution. Temporary comparison environments were removed. Unknown browser versions are not patched; restoring the same verified build is handled at normal launch. This is a launcher fix, not evidence that all Ubisoft games or account flows work.

Implementation: [UbisoftBrowser.swift](../Sources/NokcanduCore/UbisoftBrowser.swift). Verification: [UbisoftBrowserTests.swift](../Tests/NokcanduCoreTests/UbisoftBrowserTests.swift), including real official bytes supplied locally rather than committed. Checkpoints: `9ea20ac` (component/setup) and `0d7fc29` (portable integration-test input). The recorded full suite completed 173 tests with five optional skips and no failures.

### EA app — retain its working client while fixing shared setup paths

The official MSI's supported symlink option and package metadata resolved the bootstrapper failure. Matching bundled C++ libraries, Microsoft's shader compiler, DXMT/cross-process support and borderless presentation addressed the tested client startup/rendering issues. Game setup uses the original downloaded prerequisite/DLC commands; download-manager status is not fabricated.

EA can restore installer-added `RUNASADMIN` flags. The retained repair is confined to registered EA game roots, backs up values, removes only the standalone token, preserves other flags, and runs again when install/repair restores it. This allowed Populous to launch without the recurring prompt. Do not strip administrator flags from arbitrary publishers or programs.

DAO's `NxCharacter.dll` existed; a dependency was missing. PE-import detection and NVIDIA's pinned official PhysX runtime restored startup. Diagnose dependencies rather than downloading a random DLL matching an error message. BC2 and DAO reached visible gameplay, but their audio issue remains open below.

See [EA implementation details](compatibility-fixes.md#ea-app-installation) and the [dated investigation](investigations/ea-gameplay-audio-2026-10-28.md).

## Game-specific findings stay scoped

- **BF1942:** shader/renderer components are reusable; video-profile commands, verified menu-copy edits and mod-restart handling belong to its built-in recipe. Unknown executable builds must not receive guessed edits. User verified mod activation and match loading on the tested setup.
- **OpenUA:** its `NUCLEUS.INI` VBO/menu-resolution settings resolved the invisible window and tiny menu in the tested edition. Keep those settings in the OpenUA-only component, not generic Wine defaults.
- **BC2:** generic borderless resizing produced an input offset. Its own fullscreen initially aligned input, but later launches still showed cropping/positioning failures. Do not call the display issue permanently solved on the basis of one successful launch.

## Open investigations and boundaries

| Issue | Current conclusion | Next useful evidence |
| --- | --- | --- |
| BC2/DAO repeating and delayed gameplay audio | Unresolved. Menu sound is not an adequate test. Buffer, driver, synchronization, stereo, sample-rate, sound-profile, older-renderer and virtual-device comparisons did not resolve BC2. Most later comparisons were BC2-only. | A recording containing actual sound; measure repeat timing; reproduce DAO separately. [Full trials](investigations/ea-gameplay-audio-2026-10-28.md#audio-trials-and-results). |
| BC2 fullscreen/cropping across launches and app switching | Not consistently solved; smaller window used during audio investigation. | Repeatable cold launch and Command-Tab sequence with window/display coordinates. |
| New browser builds or other launcher workarounds | A hypothesis until the exact app/version is tested. Ubisoft's patch is not a generic CEF default. | Verified binary identity, a controlled comparison, visible rendering, restart/update behavior and Undo. |
| Compatibility beyond startup | Running processes, passing tests and a visible sign-in form do not prove gameplay, audio, input, downloads or DRM compatibility. | Record each tested layer separately, with edition, hardware, engine, renderer and date. |

## Keep this knowledge current

For each new issue, follow the [recording checklist](index.md#recording-new-findings). Add durable findings to the relevant implementation notes and update this status summary; retain detailed unsuccessful trials in a dated investigation. Link tests/commits and explicitly correct earlier conclusions when later evidence contradicts them. Do not promote an experiment to a default merely because it sounded plausible.

## Fullscreen containment is a presentation capability, not a window-style flag

Wine 10 explicitly disables virtual desktop configuration for the native Mac driver. The existing borderless helper changes frame styles and geometry; it does not emulate a display or scale/remap game input. A general resizable fullscreen-in-a-window feature needs a verified presentation backend and renderer/input support, then shared settings/profile integration. Do not enable an ineffective checkbox or claim universal support. The [dated feasibility record](investigations/windowed-fullscreen-feasibility-2026-10-29.md) includes primary-source evidence, the proposed prototype boundary and release acceptance tests. No new mode is implemented or tested yet.

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

## Shared graphics inference (2026-11-01)

No recognized graphics API is an unknown result, not evidence of DirectX 8–9. Shared PE inspection now includes delay imports and bounded, agreeing sibling-game evidence for generic bootstrap launchers. New automatic selections use Compatibility when detection remains unknown. Existing settings are preserved: use **Check graphics requirements** in Graphics to review and apply a journaled correction; manual launchers retain hash protection and confirmed modes are not silently replaced. The installed Rocket League regression detects DirectX 11 behind `Launcher.exe`; gameplay is not verified. See [investigation, scope, migration and Undo](investigations/graphics-detection-2026-11-01.md).

## LAN discovery is separate from direct joining (2026-11-01, resolved on Windows host)

The user disabled the Windows host’s virtual Ethernet adapter and confirmed that the Mac now sees its Battlefield 1942 LAN game. This establishes virtual-adapter involvement, not the exact socket binding/routing mechanism. No shared Wine broadcast patch or Mac firewall change was required. Do not automatically disable adapters for other users or games; inspect physical/virtual interface bindings first. Undo is re-enabling the same host adapter (the discovery failure may return). See [evidence, scope and Undo](investigations/lan-discovery-2026-11-01.md). The reusable read-only query tool has two passing local UDP tests; post-change joining/gameplay and other games were not retested.

## BF1942 Internet directory is separate from LAN discovery (2026-11-01)

Confirmed: the verified installed executable points to non-resolving `master.bf1942.sk`; the community master `master.bf1942.org` answers TCP 28900. The built-in BF1942 menu/mod-restart copy generator now replaces both verified padded hostname slots, preserving the original executable. Existing journal-owned copies migrate only with an unedited managed launcher and while the game is closed; explicit settings remain intact. Combined recipe Undo is available in Display. The old five-byte-only description below/above is historical: the current generated copy additionally changes six hostname bytes across two slots. Full suite: 203 tests, 6 skipped, zero failures. The user confirmed LAN browsing after disabling the Windows host’s virtual adapter. The first Internet correction failed because it changed only one of two hostname slots; after the two-slot revision, the user confirmed that Internet servers appear. Browser population is verified; public joining/gameplay has not been retested. See [hashes, evidence, migration and Undo](investigations/bf1942-internet-browser-2026-11-01.md).

BF1942 follow-up: the first installed Internet correction was incomplete because there are two identical old-hostname strings. Runtime tracing confirmed the browser still used the second. The revision updates both verified slots and asserts that no obsolete hostname remains, with a new full-file output hash and migration from the first attempt. The revised 203-test suite passed before installation; the user then confirmed that Internet servers appear in the installed game. Windows reportedly works with the same game folder, but its resolver/hosts settings and launch target were not compared. See the dated investigation for the failed first comparison; do not reinterpret this game-specific endpoint correction as a universal Wine networking patch.

Final verification (2026-11-01): user confirmed both LAN discovery (Windows virtual adapter disabled) and Internet server-list population (two-slot BF1942 master correction). Preserve the distinction between host-wide adapter configuration and a game-specific directory endpoint correction. Do not extend the BF1942 hostname patch to unrelated games; apply shared diagnostic and migration protections wherever relevant. Public-match joining/gameplay and other games were not retested.

## Shared legacy networking and profile completeness (2026-11-01)

The optional `ipx-networking` component installs checksum-pinned IPXWrapper 0.7.2 through the common protected installer for eligible private 32-bit games. It is not tied to ROM2’s name. Existing differing files/links are refused, native DLL rules are private to the game, and normal Undo preserves unrelated settings. ROM2’s engine returned Winsock 10047 without it; local IPX send/receive and legacy DirectPlay initialization passed with it. Basic TCP/IP passed with and without the wrapper. The user subsequently confirmed ROM2 hosting and cross-machine TCP/IP joining. Native-IPX discovery against the unchanged Windows 98 VM remains unresolved; see the native-IPX investigation below.

Saved/shared profiles include this trusted component ID automatically; the separate live service allowlist was also updated and checked against all 11 current fix IDs. New fixes must pass both app round-trip tests and service allowlist/normalization checks (`Tools/profile-check/`); do not silently lose a fix during sharing or publish DLL bytes/adapter identifiers in profiles. See [evidence, scope, installer protections, profile service change and Undo](investigations/ipx-rom2-networking-2026-11-01.md).


### Legacy DirectPlay IPX hosting requires more than provider initialization

IPXWrapper 0.7.2 exposes legacy send callbacks; Wine 11's builtin DirectPlay can
call an unset extended group-send callback on host player creation. The corrected
shared IPX component supplies checksum-pinned Microsoft legacy `dplayx.dll` and its matching provider/session helper in the private 32-bit system directory,
with an owned-file/settings migration, unchanged profile ID and normal Undo.
Always test Open/CreatePlayer, not only DirectPlayCreate or AF_IPX socket loopback.
See [the ROM2 investigation](investigations/ipx-rom2-networking-2026-11-01.md).


### Installation progress must not own the whole library

A modal installer sheet blocked unrelated games even while setup ran as a separate
Windows process. Installation now has its own window and an app-owned model, so
closing/reopening progress retains the executor, log and in-flight work. Only
completion or explicit removal clears the session. Keep every setup entry point
on this shared path; test library interaction with progress open, plus close/reopen.
See [the investigation](investigations/nonblocking-installation-2026-11-01.md).


### Preparing a destination is insufficient unless setup uses it

An external-drive link at `C:\Games\<name>` did not influence GOG's default
`C:\GOG Games\<title>`, causing a second full transfer. Recognized Inno installers
now receive their documented `/DIR=` argument for the verified prepared folder.
Unknown formats keep interactive setup and an explicit destination instruction;
retain safe relocation for paths the installer/user still chooses differently.
See [the destination investigation](investigations/installer-destination-2026-11-01.md).


### Native Ethernet IPX: gameplay verified; shared optional component

The user confirmed native IPX discovery, joining and gameplay from unchanged
Windows 98 into Mac-hosted ROM2, with the Mac on Wi-Fi and the Windows host on
Ethernet. A cable is not required for that tested setup. Wine needed its omitted
wpcap module, Darwin immediate/nonblocking capture translation and a real
`pcap_getevent` implementation. Capture alone was insufficient: IPXWrapper’s
DirectPlay provider uses a different discovery protocol from the original Microsoft
provider. The optional shared `native-ipx-networking` component uses the compatible
private Microsoft provider plus the matching capture module. Normal UDP IPX remains
available. Runtime enablement is private 32-bit Wine 11 only; SPX is unsupported.

The new component has guarded file/registry ownership, base-component dependency,
local LAN-adapter and portable frame choices, generated-launcher integration and
normal Undo. User-launch-only packet authorization is session-bound: access remains
available until the last native-IPX game closes, with no fixed match timeout.
Profiles do not grant packet access. Profiles include the native ID and schema-2
`nativeIPXFrame`, never MAC/interface/permission state. The shared validator supports
both and all 12 fix IDs; native frame round trips and invalid inputs were checked.

The signed 0.12.2 development update and guarded ROM2 migration are installed.
The complete pre-adapter suite passed 212 tests with seven optional skips; all ten
focused native tests passed after the adapter correction, including official-package
installation and migration/Undo. macOS can redact a Foundation-launched ifconfig
MAC to 02:00:00:00:00:00, so the shared code now reads the actual adapter identity
through a fingerprinted Wine adapter reader. Only unchanged owned placeholder
settings migrate; original Undo values, manual edits, frames, saves and content
are preserved.

The user confirmed normal permission approval opens ROM2. After game closure,
the session manager exited, removed its state and restored BPF ownership to
root:wheel 0600. The final discovery failure was traced to a VM snapshot restoring
NAT mode. With the VM bridged again, the user confirmed discovery and joining in
both hosting directions. Earlier Mac-hosted gameplay also passed. No VM game or
system DLL changes were required. Record bridge mode when diagnosing snapshot
regressions; local capture tests alone do not prove peer connectivity. Other games
use the same optional infrastructure but still need their own interoperability test.
See [confirmed evidence, failed comparisons, migration and Undo](investigations/native-ipx-mac-2026-11-01.md).


### External game folders: native entry identity and honest runtime sizing

A moved Battlefield 1942 failed because macOS attributed its script-only app to
/bin/bash and denied removable-volume access to shasum without a prompt. The shared
native entry retains the game's identity, preserves the script and lets macOS ask
normally. After approval, the user confirmed Battlefield opened. Closed owned
custom/recognized recipe launchers migrate safely; edited scripts/helpers/plists
are preserved, and the private record supports guarded Undo. Fresh general installs
and Steam shortcuts use the same entry. Startup receipts and a shared observer
turn early launcher failures into visible errors with bounded log detail; pending
permission/sign-in dialogs remain waits, not failed launches.

Move To on game-files-only filesystems keeps Wine and the private Windows setup
locally. The old UI showed private APFS blocks as allocated size (Battlefield about
17 MB instead of 1.94 GB), obscuring this runtime. Usage and move-capacity estimates
now count allocated blocks without following external links; deletion savings keep
private-block semantics. Shared APFS clones can make removal savings smaller than
allocated app totals. Game files were verified on Elements (Battlefield 4.82 GB);
no runtime/content deletion or reformat is required. See the
[confirmed launch, storage, migration and Undo investigation](investigations/external-game-launch-storage-2026-11-02.md).


### Verify clean packaging inputs, not only a prepared developer tree

CI's three native-adapter unit failures on `4cf2429` depended on a prebuilt adapter
reader available only on the developer Mac. Fake-Wine tests now supply explicit
packet-package fixtures; native entry tests build their helper from source. Real
package interoperability remains opt-in. Verify the test-before-build order in a
fresh tree and the GitHub result. See [the CI investigation](investigations/ci-clean-tests-2026-11-02.md).


### Microphone off must cover setup and capture, not just enumeration

**Follow-up correction:** Zero Hour proved the earlier prompt guarantee incomplete. Off also requires omitting the macOS microphone declaration, and the guard must cover Core Audio’s legacy device APIs. On preserves normal eligibility and input forwarding. Shared-client consent follows the responsible parent; do not mistake an enabled parent’s capability for permission to capture in an Off child. See [confirmed evidence, failed alternatives, migration and Undo](investigations/microphone-playback-permission-2026-11-02.md).

The microphone flag was exported after an earlier Wine setup call, audio-follow
registered input listeners regardless of the switch, and cached endpoints could
reach capture EnableIO. Shared Steam also omitted its per-game microphone choice.
The shared correction applies explicit policy before Wine calls, propagates it to
tools/child environments and per-program settings, and blocks input queries,
listeners and capture setup while preserving output. Steam-client consent is a
separate opt-in from each game's switch. Existing explicit choices and manually
edited scripts are preserved; unchanged generated scripts/helpers migrate normally.
A separate Wine 11 probe reported zero inputs and four outputs with microphone off;
hardware-free native tests verify both policy states. The user confirmed no microphone prompt on a fresh launch. Saved prefix/program
policies also enforce off when a child drops the inherited environment; a separate
output-only probe passed with the environment flag removed. TCC capability checks
can still occur during output-only use and do not establish input capture. The full
suite passed 233 tests with seven optional skips. See [scope, evidence, migration and Undo](investigations/microphone-off-enforcement-2026-11-02.md).

### Shipped recipes are editable defaults, not a settings lock (2026-11-02)

Recipe installations lack `CustomGameConfig`; do not use its presence as a proxy for movable content or configurable Wine settings. Resolve the recipe's dedicated content folder centrally and retain specialized launch methods when layering user overrides. In particular, Zero Hour must keep the tested .NET `Launcher.dll` path by default. Marked additions must normalize back to the recognized launcher for migration, display and repair checks. Preserve manual edits. Test ExFAT content relocation with the existing C-drive link, return moves, literal shell arguments, performance reads, and profile Undo. See [the confirmed investigation](investigations/recipe-storage-settings-2026-11-02.md).

### Live microphone consent must account for cached endpoints (2026-11-02)

The earlier hidden-device implementation is correct for startup isolation but prevents enabling a microphone in an already-running Wine process: Wine caches its endpoint list. Live mode separates read-only discovery from capture authorization. Keep HAL playback's legacy query guard and Off purpose-metadata removal; enforce permission at EnableIO, active capture Stop/Start and Render. Read policy off the realtime thread and serialize unit disposal against background changes. Save only the microphone choice while a game runs, preserving launcher bytes, ownership hashes and unknown settings. A same-process scratch-prefix test confirmed refused startup, real samples after On, stopped delivery after Off, and resumed samples after On. See [verification, limitations, migration and Undo](investigations/live-microphone-switch-2026-11-02.md). Older reports of zero inputs while Off describe the pre-live mode, not the new discoverable-but-blocked mode.

First-use caveat: macOS caches missing purpose metadata in a session started Off. Adding it mid-session did not prompt in the fresh-identity test; first authorization may require one close/reopen with On. The no-restart capture test used an already authorized identity.

### Preserve program identity before Wine rewrites argv; keep polling off the UI (2026-11-02)

A per-program microphone policy must not repeatedly resolve `_NSGetArgv()[1]`: Wine removes its loader argument and can overwrite the argument strings. Copy the executable identity in an early constructor, then read its mutable policy separately. A private-prefix On capture test does not validate routing under a shared prefix's blocked default. Also, synchronous process scans on a repeating UI timer can make every click beachball; coalesce one background status pass using one shared process snapshot. Repair must restore owned audio/input helpers in the owning host before shared-shortcut early returns and report that loaded processes need reopening. See [evidence, scope, migration and Undo](investigations/shared-microphone-routing-ui-repair-2026-11-02.md).

Installed validation: the user confirmed working CS2 voice input and live microphone switching after the shared identity fix. The full suite passed 248 tests with ten optional skips.

### macOS closed sockets can become false Winsock exceptions (2026-11-02)

A BF2Hub login hang can occur after TCP authentication has already connected, while a later GameSpy HTTP request waits on a gracefully closed socket. Independent loopback tests reproduced Darwin's closed-socket urgent-event indication being exposed in Winsock's exception set. The shared helper now normalizes only confirmed clean TCP half-closes inside wineserver, preserving real urgent data, refused connects, resets and errno. It avoids changing game renderers, server protocol or account endpoints. Synthetic tests passed on Wine 10 and 11 and both Windows architectures. After activation, the user confirmed actual BF2Hub login and a populated server browser; joining/gameplay remain a separate check. See [scope, evidence, migration, profiles and Undo](investigations/wineserver-closed-socket-readiness-2026-11-02.md).


### Helper activation, process-scan failure and companion recovery (2026-11-02)

An installed helper hash does not prove live Wine processes loaded it. Track the embedded helper build with PID plus kernel start time, include daemonized wineserver children through both poll and kqueue (Wine 11 can bypass poll), and compare against both the installed bytes and current bundled build. Show restart-needed separately from Repair-needed; never restart a working game automatically. A failed or overlapping process scan is unknown, not evidence of exit: retain prior UI running state, suppress cloud-save exit uploads and refuse closed-game mutations. Perform scans outside the cache lock and UI actor.

Repair now checks the shared helper, screen tool, native app entry, generated Wine wrappers and installed compatibility companion binaries. Preserve manually edited launchers/entries and linked destinations. Store hash-verified recovery copies only for small journal-owned companion binaries; restore missing files only with verified payloads, and report unavailable recovery or external edits rather than claiming success. Capture wrapper hashes after signing and store them outside the signed wrapper. See [scope, migration, evidence and Undo](investigations/helper-activation-repair-hardening-2026-11-02.md).

BF2 follow-up: the user confirmed Internet account login, populated servers, joining a multiplayer match and moving around. Real Wine 10/11, 32/64-bit closed-socket tests now run in CI with pinned engine archives, synthetic loopback responders and disposable prefixes; refused connections, urgent data and resets must stay visible. Extended sessions/all anti-cheat configurations are not established by that result.

### Storage settings performance (2026-11-03)

A detached disk scan can still be expensive if every settings appearance repeats all categories, blocks presentation on the slowest category, and eagerly builds every row. Load only the selected Storage section, virtualize long lists, show names before sizing, and reuse recent session estimates with explicit Refresh. Coalesce scans and guard both invalidation and superseded completions; canceled UI requests must not publish into another section. Keep folder-capacity queries and cleanup off the UI thread, and revalidate cached orphan rows before Trash. Preserve storage accounting definitions and move safety checks. See [scope, cache behavior, verification and Undo](investigations/storage-browser-performance-2026-11-03.md).

### Storage location coverage must be shared (2026-11-03)

The Games inventory and game-detail summary must not maintain separate location rules. Resolve launcher registration/manifests and known native install data as well as private linked content; a selected hub executable can be outside the actual game directory. Keep discovery bounded to dedicated game containers, deduplicate canonical roots, and exclude separately listed game content from shared launcher inventory rows. Unknown/unavailable game content is an incomplete estimate, not a complete tiny-app total. Moves must invalidate session measurements even when the app path/config is unchanged. [Evidence, scope, migration and Undo](investigations/storage-game-location-accounting-2026-11-03.md).

### Installer media is not a permanent game drive

Wine may map a mounted native installer image into otherwise unrelated private environments. Never infer safe removal solely from an offline `/Volumes` path. Track only newly created mappings proven to belong to an attached disk image during managed initialization/update, preserve explicit mappings and game/registry references, and clean up unchanged link pairs only in reliably closed environments. Unknown historical mappings require explicit authorization. Record recovery before unlinking; Undo must not overwrite a reused letter or block the UI. [Evidence, migration, protections and limits](investigations/automatic-installer-drives-2026-11-03.md).

### Store completion must update the library independently of store views

Use local installed-game readers in one background discovery path, with a single in-flight scan and a bounded poll interval. Add by stable product/host identity, never by display name; share an idempotent creation transaction with manual Add. Preserve existing settings and intentional removals, distinguish offline folders from uninstalls, and avoid recreating shortcuts on disconnected app libraries. A retained installer should notify the library after its self-check, without requiring window dismissal. [Implementation, evidence, migration and Undo](investigations/automatic-store-game-discovery-2026-11-03.md).

### Wine selection is explicit, scoped and persistent

A global installation default must not migrate existing games or unfinished installs. Snapshot it when new work starts, preserve legacy resume semantics and allow a per-install override only before preparing Wine. Game dropdowns resolve the actual Windows host, clearly state shared-client scope, keep the existing rollback transaction and record fresh selected-runtime provenance for Repair. Use checksum-verified official Sikarugir engines from Wine 10 onward with the verified wrapper; preserve dependent-feature requirements and cache entries needed by defaults/unfinished work. [Design, validation, migration and Undo](investigations/wine-version-selection-2026-11-03.md).

### Saving desired settings must not require restarting a game

Persist typed changes separately from applying them. Active/unknown Windows sessions defer safely, idle infrastructure can close without relaunching a game, and fresh process evidence must authorize mutations. Keep pending state outside active app bundles; a live clone rejected new bundle-internal writes. Reuse one application path for Play and app icons, serialize application while allowing further saves, preserve failures for retry/discard, and show requested/pending values. Live microphone/mouse controls keep their immediate behavior. [Evidence, migration, tests and Undo](investigations/deferred-game-settings-2026-11-03.md).

## App updates need independent recovery (2026-11-03)

Save a verified Nokcandu app copy before both upgrades and rollbacks. Use one replacement path for local backups, verified published releases and developer installation; never proceed after a wait timeout. A UI-only rollback is insufficient for a release that cannot launch: keep a separate recovery command/helper outside the replaced app. Preserve game/runtime/settings data, refuse stale plans and keep damaged originals for investigation. Signed-resource fingerprints detect resource-only changes as well as executable changes. See [app-version rollback](investigations/app-version-rollback-2026-11-03.md).

## Test engine upgrades with existing identity wrappers (2026-11-03)

A scratch-engine self-test and a historical Wine 10 selection do not cover Wine 10 → 11 with an existing Wine 10 game wrapper. Upgrade preflight must run the new loader directly, retaining privacy policy. Both helper redirection paths must reject stale wrapper engine stamps, and utility classification must accept `wineboot`/`cmd` before `.exe` resolution. The Falconeer clone reproduced the reported ntdll path failure and verified upgrade plus exact engine/registry rollback after correction. See [stale-wrapper investigation](investigations/wine-upgrade-stale-wrapper-2026-11-03.md).

## Distinguish blocked capture from suppressed consent (2026-11-03)

A refused input-open call, Off policy and previously allowed OS permission do not prove a fresh launch will avoid a microphone dialog. The Falconeer report demonstrates the gap. Trace the earliest consent-requesting call and check fresh identities; record the difference between a silent OS refusal and no request at all. The unresolved prompt is disclosed in both 0.12.3 and 0.12.4; the former 0.12.4 target was not met. No new fix version is promised; see [the open investigation](investigations/microphone-off-prompt-2026-11-03.md).

## Launcher architecture is not game architecture

A 64-bit borderless launcher can start a 32-bit DirectX 8 game: the Moongamers BF1942 installation reproduced a false compatibility refusal. Resolve only an unambiguous, directly evidenced adjacent DX8 target inside the managed folder; preserve the selected launcher. Artwork selection is independent of program selection and must not regenerate launchers or change arguments. See [evidence, scope, tests and Undo](investigations/launcher-dx8-and-icon-editing-2026-11-03.md).

BF1942 resolution-only receipts must not own the launch program. The save guard now distinguishes these from the recommended menu-copy recipe, and Undo preserves later program choices. Recognizing the known Borderless1942.exe wrapper, retaining content validation, and resolving receipt-owned Undo paths keep recovery reachable without offering BF1942 recipes to unrelated programs. The saved pending request remains retryable. Nine focused launcher/icon/profile regressions passed.

Profile application must share one complete operation across catalog/local profiles and note snapshots. Notes previously restored settings without installing listed components. Both UI paths now use `Profiles.applyComplete`, which returns explicit partial-result reasons and tracks newly added compatibility components for Undo, preserving earlier installations. The focused component/apply/reapply/Undo regression passed. Cinematic/LAV keeps its separate component Undo. [Investigation](investigations/launcher-dx8-and-icon-editing-2026-11-03.md).

BF1942 Moongamers menu crash at `0x007fbeb2` was resolved in the user test by changing the active profile’s `game.setHardware 1` to `0`; online match joining also succeeded. This establishes a hardware-audio workaround, not its internal root cause or a renderer defect. Optional `bf1942-software-audio` applies it only to BF1942’s safely identified active player profile, preserves unrelated audio settings with key-level Undo, and is captured/applied by profiles. Reapply after changing player profiles. Original diagnostic settings are retained locally. [Evidence and limits](investigations/launcher-dx8-and-icon-editing-2026-11-03.md).

Final combined verification: 335 tests, 14 optional skips, zero failures; required Wine/IPX production package built and installed through app-only recovery, with strict/deep signature verification. Installed UI shows independent icon editing, BF1942 software sound and reachable display Undo. No live profile or game settings were changed during UI verification. BF2 Spaces input and microphone-Off prompts remain outside this fix.

A built-in compatibility fix must be accepted by both the app and the separate profile catalog validator before users share it. The missing `bf1942-software-audio` catalog ID rejected issue 22 as “unknown fix”. Companion `8005d70` adds it, gives explicit unknown-ID errors and enables revalidation; the issue is now valid and in the published catalog. App CI checks all 13 IDs against the companion source allowlist without executing downloaded code. [Evidence and scope](investigations/profile-validator-parity-2026-11-03.md).

BF2 native-fullscreen Space-away/back input loss remains unresolved. A deferred focus re-offer candidate passed native safety tests but failed the actual game comparison; minimizing/restoring recovered controls. The user reported better behavior with BF2’s resizable virtual screen Off and deferred the investigation. The temporary driver and active build/source candidates were removed; no shared focus fix was shipped. Preserve the working Off setting and do not claim the first candidate solved the issue. [Findings and cleanup](investigations/fullscreen-space-input-2026-11-03.md).

November 4 profile follow-up: an isolated end-to-end run installed all five BF1942 profile components from actual pinned packages and built helpers, applied resolution-only settings, verified matching PE DLLs/receipts and profile capture, then successfully undid the operation with original sound/display settings, program and environment restored. This tests the shared `applyComplete` installation path without launching a game. It supports the missing-component bug fix, not a guarantee that all profiles work with every game. See [verification details](investigations/launcher-dx8-and-icon-editing-2026-11-03.md).

## Drain deferred work on idle observation (2026-11-04)

A durable setting queue with launch preflight is incomplete if normal session polling never applies work after exit. Use the same protected executor from an independent background monitor, retain active/unknown-session deferral, and recheck activity between operations. Coalesce polls and remember failed request sets to avoid repeated downloads/errors. Pending-control indicators must compare desired values to persisted settings rather than the UI preview, and distinguish host-wide settings from per-game settings. See [idle application](investigations/pending-settings-idle-2026-11-04.md) for scope, verification and Undo.

## Verify the actual CI toolchain and terminal network errors (2026-11-04)

A local test pass is not evidence that GitHub CI passed. Non-sensitive stage markers localized an older-runner XCTest crash to the pending monitor's async call; replacing default async callback values with nil injection and direct production calls passed the runner's full test step. Keep callback behavior covered rather than removing the test. A nonblocking connect probe must distinguish an immediate terminal refusal from an asynchronous failure notification; checking only select can reject valid synchronous error delivery. The earlier log lacked the initial connect result, so do not present that explanation as retrospectively proven. [Investigation and verification](investigations/ci-pending-monitor-and-refusal-2026-11-04.md).

## Label actual state, not unexplained development status (2026-11-04)

The installer’s unconditional Preview badge had no behavioral meaning and confused real installation progress. Removed it from the shared header for all installation flows; no state migration is required. See [installer notes](investigations/nonblocking-installation-2026-11-01.md).

## Scope shared-launcher components to registered game programs (2026-11-04)

A shared prefix is not a reason to block all compatibility components. Resolve a dedicated registered game root and actual PE program, keep receipts and DLL rules on its shortcut, and apply them before DLL search initialization through complete-path routing. Whole-folder removal rules are too strict for games nested inside a client; component validation must instead ensure the client is outside the selected game root. Receipts must keep targeting stable across UI renames. Treat incomplete installs as inactive recovery records, and never export them as working profile fixes. Shared profiles must not redirect game graphics to client settings or restore unrelated shared preferences that they never changed. See [implementation and evidence](investigations/shared-launcher-compatibility-2026-11-04.md).

## Request platform-specific runners only for platform-specific work (2026-11-04)

A scheduled engine watcher failed before executing any step because GitHub could not supply its hosted ARM Mac. Retrying succeeded. Run version discovery on a general runner and request macOS only for a genuinely needed native build; do not classify runner-capacity failures as product build defects. [Evidence](investigations/ci-pending-monitor-and-refusal-2026-11-04.md).

## Poll cheaply, rarely in the background, and never on the main thread (2026-11-04)

A 3-second status pass that hashed helper libraries and built file URLs for every process on the Mac cost ~25–40% CPU while idle and competed with games. Ownership tests must be string comparisons against a precomputed real path (remember `/private` prefixes and symlinked apps), hashes must be cached by file identity, and expensive passes should run on change events (app launch/quit, drive mount) with slow background polling. Library scans and anything reading per-game files must stay off the main actor; publish values only when they change. [Measurements](investigations/space-efficiency-moves-2026-11-04.md).

## Report clone-aware sizes and bound every safety copy (2026-11-04)

Each Wine app's engine is an APFS clone, so allocated size overstates what a game uses (BF2: 2.9 GB allocated, 12 MB unique). Show unique size and the shared part separately. Restore points, roll-back engines and logs need limits and an owner: restore points cannot cross drives, so a move must relocate or replace them, and orphaned sets must be offered for deletion. ExFAT drives with large clusters can multiply small-file games several times; suggest an APFS volume rather than reformatting. [Details](investigations/space-efficiency-moves-2026-11-04.md).

## A move must update every record that names the old path (2026-11-04)

Saved install progress kept the old app path, so moved games looked unfinished and the installer resumed a stale record; background writers that started before the move recreated a ghost folder at the old path. Moves now relocate install records, maintenance skips games being moved, settings writers refuse to create a missing app, and existing ghosts/records are reconciled. Launchers whose path many records share move with a link left behind instead of rewriting every reference. [Details](investigations/space-efficiency-moves-2026-11-04.md).

## Controller mouse-event identity (November 10, 2026)

Desktop controller movement must derive event type and button number from the same held button. Previously left+right chose left-drag with right button; middle/extra held buttons produced ordinary moves. `PadMouseEvent` centralizes desktop event construction and tests all 32 held-button combinations plus release transitions, with delta/location/flags checks. No profile migration or installed game modification. This confirms an event-construction defect, not a fix for Overwatch delayed aim or BF1942 click jumps. See [Phase 0 investigation](investigations/controller-overhaul-2026-11-10.md) for architecture, pending manual validation, opt-in route diagnostics and Undo.

## Controller overhaul continuation (November 10, 2026)

Input receipt, event emission and target consumption are separate acceptance gates. The current incremental changes add opt-in process-directed mapped pointer capture (not physical mouse seizure), event marking, captured click ownership, foreground release, callback-independent editor previews, conservative binding-only live updates, persistent key/mouse toggles, button routing and source-aware hold composition. Profile backups precede first new-feature save; old decoded macro timing stays unchanged. Native macOS suppression and virtual controller identities remain unproven. The unchanged HEAD reproduces all four privacy-test failures under denied process inspection; retain unknown-process safety. See the [implementation checklist](investigations/controller-overhaul-2026-11-10.md#progress-checklist) for tested scope, pending software/hardware gates, research, migration and Undo. Experimental headphone motion uses the documented API and starts disabled; no audio, pairing or permission changes were performed.

Sequence cleanup must track as many outstanding down-events as the accepted step count. The previous six-output chord container was too small for a longer sequence: untracked keys survived normal macro completion. The shared macro ledger now accommodates 48 steps and releases in reverse order; eight-key completion/cancellation tests cover the regression. Explicit mapped-only button routing must also disable unbound passthrough, not merely omit a binding. The Wine reload owner now uses the same conservative binding-update API as DesktopPad.

## Live timer ownership and manual capture recovery

Ordinary hold/double/turbo timers should not force unrelated bindings to restart during an edit. The shared binding-update path now preserves unrelated deadlines, cancels changed-input deadlines, and treats identical compiled text as a no-op even during latched output/sequence execution. Turbo off-phase releases previously decremented shared output counts twice; tracking the off phase prevents another input's hold from being released. Regression tests cover both phases, overlapping holds, cancellation and equivalent saves. Manual capture now forgets activation after missing window/permission or rule changes; disabled rules skip repeated window enumeration. See the [continuation evidence](investigations/controller-overhaul-2026-11-10.md#live-timers-and-authorized-mac-inspection-continuation). Remembered controller assignment rows are not proof of a connected device.

## Compatible controller tuning and exact application targeting

Numeric stick/gyro edits can preserve the running engine when output topology and all other compiled lines match. Keep configuration separate from dynamic state: the stick acceleration accumulator was moved into the runtime portion before copying configuration prefixes. Tests verify acceleration, holds, layers, macro/toggle state and next-sample sensitivity. Structural output changes still rebuild safely. Application capture inheritance now requires an explicitly selected canonical wrapper path and an exact generated helper layout; remembered names are insufficient. Canonical path comparison avoids file-URL directory-metadata mismatches. See [implementation and Undo](investigations/controller-overhaul-2026-11-10.md#compatible-live-tuning-and-exact-wrapper-targeting).

## Controller route composition and debounced editor persistence

Selective stick/trigger/gyro routing now shares the C engine with buttons. Native/Both analog contributions use strongest magnitude on a shared output axis rather than summing the same physical input twice; Disabled/Mapped suppress legacy raw fallback where appropriate. Native sensor/device identity must not be promised merely because mapped output is off. Editor persistence now coalesces committed edits for 250 ms while runtime reads pending values immediately. Scope own profiles by canonical persistence-source path, flush before structural profile actions, and reject stale scheduled callbacks to avoid recreating deleted profiles. Exact tests and rollback are tracked in the [investigation](investigations/controller-overhaul-2026-11-10.md#axis-routing-persistence-and-real-pro-controller-receipt). A GUI probe received continuous Pro Controller motion callbacks while Steam and installed Nokcandu ran, despite the CLI probe seeing no devices; keep evidence scoped to the process and actual connection session.

## Controller cleanup ownership and safe profile persistence

Cleanup must cancel input without creating a radial-menu choice, virtual tap or new pulse. Track activating source across toggle/macro/timer outputs, release removed/replaced slots independently, and refuse a pulse if no release timer can be allocated. Sequence wait allocation failure must unwind held outputs. Tests exercise queue exhaustion and unrelated owners. Validate existing profile JSON before replacing it, back up own as well as shared profiles, and never recursively delete an unexpected controller-map directory/link. Report partial map refresh explicitly while retaining saved settings and good map updates. The four earlier privacy failures reproduce at unchanged HEAD under denied process inspection; per-fixture process observations make those tests hermetic without weakening production unknown-state safety. [Evidence, limits and Undo](investigations/controller-overhaul-2026-11-10.md#ownership-recovery-and-test-delivery-continuation).

A window-local target input monitor is useful separately from adapter receipt counters. The new Help input test returns local events unchanged and throttles display to 10 Hz; its isolated preview verified UI event receipt/reset/normal quit without initializing the real library. Preserve the distinction between computer-control events, physical controller receipt and game consumption. Compatible basic stick output changes can now preserve state; keyed/directional/flick/mixed structural changes still use replacement. [Test procedures](controller-overhaul-testing.md).

The test package passed deep signature/plist checks with the new universal helper; selected regression run executed 131 tests with one environment skip and no failures. A clean temporary SwiftPM scratch/native build avoided a denied existing dSYM update. Build-only environment overrides leave normal build/install defaults intact. The staged copy is ad-hoc signed and may need a separate user permission decision; it was not installed or launched against the real library. Existing iconutil failure is a documented nonfatal packaging limitation.

Binding-edit compatibility should depend on actual active owners rather than the mere presence of a macro, pulse or simultaneous timer. Stable binding-table addresses and by-value output stores allow unrelated live edits to preserve original deadlines. Affected owners/peers still use the nonmutating rejection/replacement path. New live continuity/rejection tests passed. [Evidence](investigations/controller-overhaul-2026-11-10.md#unrelated-running-actions-during-editing).

Persistent layer/gyro latches are separate owners from a button's active press outputs. Replacing their activating binding must clear the owned latch after table replacement, while retaining unrelated holds/latches. Before/after regression tests verify base-layer/gyro restoration and captured held-key cleanup. [Evidence](investigations/controller-overhaul-2026-11-10.md#replacing-latched-mode-bindings).

## Toggle discoverability and compatible key-stick updates

Persistent-output support hidden in an Add submenu is insufficient discoverability. The button inspector now exposes Toggle beside While held and explains first-press latch/second-press release; controller-button/trigger output latches share the same ownership/refcounts as key/mouse. Distinguish logical Wine output from native virtual-device capability. Switching a key-stick's codes must release the old codes before copying configuration; overlapping owners must retain their references. Full release must clear gyro activation flags as well as held outputs. Regression/model/backup tests passed, with isolated real-editor UI verification. Optional local timing aggregates and an offline counting-sink benchmark explicitly exclude end-to-end hardware/game latency. [Evidence, migration and Undo](investigations/controller-overhaul-2026-11-10.md#directional-key-updates-visible-toggle-behavior-and-timing-diagnostics).

Local recording decisions are now independently testable: Escape cancels without creating an output and resets modifier state. Monitor lifetime remains a UI responsibility with disappearance cleanup. Automated UI keyboard targeting introduced a click before Escape in the preview comparison; this did not isolate a human starting-click bug. A deferred-install trial did not help and was removed. Keep deterministic recorder tests separate from confounded UI/hardware evidence. Final selected run: 159 tests, one environmental skip, zero failures; sanitized offline engine-update smoke passed.

A staged app is not the running installed app. After explicit install authorization, use the app-only recovery installer, verify executable identity, reopen the exact usual path and check the real editor. The installed Toggle UI is now verified; renewed Accessibility authorization is a separate security-sensitive step. Do not overwrite profile changes the user makes concurrently during UI inspection.

Controller-picture toggle labels must name the actual held output, not just its action category. Reuse the existing output title and effective press-output conversion so explicit toggle metadata and old toggle tokens agree with the inspector. Compact label scaling plus full hover/accessibility text preserves discoverability. [Evidence](investigations/controller-overhaul-2026-11-10.md#toggle-output-labels-on-the-controller-picture).

For this ad-hoc update, a stale macOS privacy entry stayed visually on while AX trust was false. On/off alone did not restore trust; user-authenticated removal/re-add of only the exact installed Nokcandu restored the app's normal Everywhere status. Permission switches alone are insufficient verification—check effective app status afterward. The installed picture's actual Toggle Space label was verified alongside restored trust; hardware acceptance remains separate.

## Signing continuity and real Wine registry fixtures

A configured keychain hidden by restricted execution must fail a build, not silently downgrade it to ad-hoc and lose the user's grants. Reuse the existing signing identity and verify incoming code against the installed requirement. Two changed test binaries have the same certificate-bound DR; full-app/TCC verification remains distinct. Wine persists CurrentControlSet as a registry link: offline edits must resolve its UTF-16 target, not create literal shadow children. Realistic ControlSet002 fixtures exposed the defect; reliable process observation is required before migration. [Evidence and open gates](investigations/signing-routing-sidebar-drives-2026-11-10.md).

Explicit Gyro-off holds now gate separately opted-in head motion and reset its transform during pause. Construct headphone-motion managers only after user opt-in, never merely to render settings or stop a disabled owner. Shared footer layout must reserve physical list space, rather than relying on sidebar inset underdraw behavior.

An explicit native controller choice must outrank automatic profile-driver adaptation. Shared profiles previously forced Xbox even for a game's explicit native selection; change only Automatic's resolution, and disclose that native routing bypasses the SDL controller remapper. Alias repair alone cannot fix a precedence bug. New tests cover a shared profile driver with explicit native plus actual ControlSet migration.

The installed signed app verifies normally and already recognizes Accessibility without a refresh; a restricted codesign verification failure was a keychain-context limitation, not justification to weaken certificate requirements. Installed sidebar/search tests verified section-first ordering, separate footer, Command-F, filtering and clear/reset.


## Scope SDL interception to Wine's caller

The empty native-controller panel was reproducible with real Pro Controller
hardware even after native policy/registry repair. An empty-prefix comparison
separated device access from helper interference: native IOHID plus no helper
registered Pro Controller; the full helper failed without any profile state.
A forwarding-only hook still recursed; stack sampling showed repeated
SDL_WaitEventTimeout_REAL, and scoped tracing showed SDL's own dlsym lookup before
Wine's. Only intercept lookups originating in winebus.so / winebus.sys.so; allow
SDL's internal dispatch and unrelated callers to keep original addresses.
The actual-helper fake-library regression fails the old hook and passes the
caller-scoped fix, including ordinary game processes. The installed real Steam
prefix and actual panel now enumerate Pro Controller 057e:2009 through DirectInput;
an isolated SDL/Xbox comparison also enumerates XInput. Original Steam hardware,
actual buttons/gyro and game acceptance remain separate. Existing running Wine
processes must exit naturally to load the helper update. [Comparisons, migration
and Undo](investigations/signing-routing-sidebar-drives-2026-11-10.md#reproduced-native-detection-failure-and-scoped-sdl-fix).

Actual changed-code updates using the same existing certificate retained effective
Accessibility without another grant. Verify the running executable path: duplicate
workspace app copies can make an otherwise valid UI observation ambiguous.


## Profile-selected experimental input and window receipt

Headphone mapping belongs in a profile's source list. Store optional per-profile
configuration with inherited removal/disable, resolve it before the runtime's
compiled-text early return (head settings intentionally do not alter Wine/C
output), and keep source creation lazy. Old profiles must remain opted out;
first-feature-save backup now recognizes headMotion. General preferences retain
status rather than global tuning. Compatible headphone identity is selected by
macOS, not a fake HID vendor/product. Hardware/audio acceptance remains pending.

A test window can show observed held outputs and ordered receipt transitions to
help users validate toggles/sequences, but focus loss invalidates that observation.
Clearing an observed set must never be presented as proof an OS key/button was
released. Keep bounded local history, no typed-character/global input capture,
and explicit local Copy rather than background logging. [Scope/tests/Undo](investigations/signing-routing-sidebar-drives-2026-11-10.md#preparation-for-user-testing-held-output-receipt-and-profile-headphone-source).


## Original Steam Controller receiver is not an awake controller

USB 28DE:1142 is the original receiver: its keyboard and four vendor interfaces
exist with the controller off. Label receiver presence separately from controller
power/pairing/input and do not advertise observed gyro from that inventory. Normal
Wine Mac IOHID rejects its vendor interface; the Pro Controller native fix does not
establish Valve passthrough. A strict opt-in, original-ID/vendor-usage-only research
patch exposed four receiver HID interfaces to Windows in a temporary engine;
default-off did not. This is a feasibility result, not Steam/profile compatibility.
WINEDLLPATH did not override the built-in engine path; a copied temporary runtime
was needed for a valid comparison. The candidate lacks SDL and must not ship.
No firmware/pairing/mode commands were used. [Evidence and next gates](investigations/steam-controller-2015-2026-11-10.md).


## Field tests: admission and coordinate spaces

Headphone activation is an independent source gate: use physical input/actual engine
layer, retain controller gyro, recenter on admission transitions and inactive samples,
and default old saved sources to Always. Resolve before compile-text equality; head
settings intentionally do not affect C/Wine tokens. Installed UI/195 regression
checks passed; real hold/layer use still needs acceptance.

Validate Wine mouse events in **Windows** coordinates, not the CGEvent's Mac point.
Presentation origin/scale and Retina broke the old learning comparison. Wine 10/11
now expose their own conversion to the helper, including tracked cursor bounds and
restoration. Explicit captured Wine moves should prefer its relative socket: the
raw-mouse hook can swallow synthetic process-posted movement. Retain default menu
behavior and native-client routing. Unknown process scans must block managed driver
refresh. Both drivers and coordinate/header/helper regressions pass; game retests
remain distinct.

A physical Pro Controller emitted stable full-state button fields while DirectInput
flipped hundreds of buttons. Its USB descriptor labels packet counter/battery bits
as buttons; a device-specific Steam reader can still decode the actual raw protocol.
Do not blame a toggle/profile or silently override As itself. Exact-descriptor USB
correction now has a full-SDL reproducible build and bounded native Windows idle
acceptance (375 successful samples/zero transitions in the repeat alongside stable
host input). Exact descriptor and stock-module fingerprints prevent applying a
protocol workaround to unrelated hardware or edited engines. Preserve a verified
original and persistent Undo opt-out; physical mapping/Steam/game acceptance stays
separate. Expanded related tests pass 200 with no failures/skips.
[Evidence, checklist and Undo](investigations/controller-field-tests-2026-11-10.md).

## Original wired Steam HID and headset stick mapping

USB 28de:1102 exposes mouse/keyboard plus a vendor FF00:1 interface. Admit only
that exact vendor interface to Wine; do not broaden keyboard/mouse matching or
confuse receiver slots with controllers. A full-SDL bus successfully opened/read
its actual Windows HID interface and preserved Pro idle stability; this is not
Steam Input/game acceptance. Preserve known-module migration and original recovery.
A passive profile reader avoids speculative device resets; report-stream freshness
must be refreshed by duplicate valid state but never status packets. Distinguish
full packet decoding tests from physically verified controls.

Headset stick control needs attitude displacement from an activation pose, rather
than mouse deltas: remaining turned must keep a key held, and centering must release.
Feed the existing source composer/C engine so physical-axis restoration, layered
key mappings and held radial menus retain their ownership. Keep mouse the legacy
default and neutralize a previous stick source on admission/output/lifecycle changes.
[Evidence and limits](investigations/steam-wired-head-mappings-2026-11-11.md).


## Controller calibration and foreground transitions — November 11, 2026

A foreground PID change must release old outputs, but need not destroy an unchanged mapping engine. Destruction discards measured sensor bias. Retain the engine only when compiled profile/source are unchanged, clear source snapshots and reattach; profile/source/forced changes retain existing rebuild behavior. Actual-engine tests verify bias, old holds/toggles release and renewed motion. This does not establish hardware-stall recovery. See [field-test evidence](investigations/controller-field-tests-2026-11-11.md).


## Verify the actual renderer before applying upstream workarounds — November 11, 2026

BF2's selected Older 3D mode was overridden by an already-installed DirectX 8 compatibility component to a legacy DXVK-Sikarugir 2.3 library. Its actual graphics log lacked the later upstream BF2 focus-loss default even though the ordinary renderer bundle was newer. Inspect effective launch exports, runtime log and option support together. Keep this proven game-specific compatibility setting scoped and opt-in, preserve explicit options, and distinguish a supported candidate from verified gameplay. [BF2 evidence and tests](investigations/bf2-deployment-menu-2026-11-11.md).


## Compatibility receipts must survive maintenance and queued edits — November 11, 2026

Live BF2 verification caught an Installed receipt whose owned setting disappeared in a later generated settings write. Read current disk configuration before automatic launcher/helper regeneration; preserve installed component requirements when applying an older queued full-custom edit. Reconcile only known receipt-owned keys and retain manual-launcher hash protection, running-session checks and explicit component Undo. Actual queue/installation/stale-snapshot/repair/Undo regressions pass. Final live flag and launcher append survive restart and Play. [Evidence and limits](investigations/bf2-deployment-menu-2026-11-11.md).


Legacy BF2 transport follow-up: supported option names do not prove support for inline DXVK_CONFIG. This installed Sikarugir fork requires DXVK_CONFIG_FILE; actual D3D9 initialization confirmed the file and exact BF2 section are parsed. The component now uses a journal-owned scoped file and Windows path, with explicit-user-file conflict refusal. Foundation can leave parent symlinks unresolved for nonexistent leaves: resolve the valid directory before constructing a new settings filename, while separately refusing leaf links. See the superseding BF2 evidence above.


Preserve owned environment/DLL requirements at the central ordinary save boundary as well as stale-snapshot callers; otherwise a new or overlooked writer can drop installed component keys again. Explicit component Undo bypasses that narrow safeguard, and non-environment config fields retain their prior semantics. Full 589-test suite passes with 19 documented optional skips. BF2's selected DXMT mode actually loaded WineD3D/OpenGL for its D3D9 game process; use actual module/log evidence for renderer comparisons.

### Preserve the stock controller runtime dependency

Wine's controller bus dynamically loads SDL by configured SONAME. An engine can contain both an obsolete unversioned SDL2 and a newer versioned SDL2 compatibility runtime. Header detection and “SDL enabled” do not establish the right runtime. Match the stock module dependency, validate the actual install name and generated configuration, and test isolated Windows enumeration with connected devices before packaging. The wrong library produced an Apple Pro alias and omitted converted Pro/Steam XInput slots. [Controlled comparison, scope and Undo](investigations/controller-priorities-2026-11-11.md).

### Mouse buttons must share the movement coordinate contract

Wine's ordinary Mac mouse-button handler adds absolute movement. A controller-relative movement followed by a CGEvent at the frozen Mac pointer therefore jumps even when button-event deltas are zero. Use a capability-gated button-only Wine queue path, preserve physical mouse behavior, and pin release to the down's process/window. Compile/test the actual patched handler, including all buttons and invalid encodings, rather than testing a duplicate formula. [Contract, evidence and pending game checks](investigations/controller-priorities-2026-11-11.md).

### Import profile layers transactionally

Layer actions can reference inherited macros and menus, and names/IDs can collide in another profile. Copy explicit settings into a fresh layer, recursively clone dependencies with new IDs, rewrite self references and reject missing dependencies or capacity overflow before replacing the profile. Never partially edit the destination on an import error. [Scope and tests](investigations/controller-priorities-2026-11-11.md).

### Original Steam Controller needs a reversible mode lease

Passive full-state receipt does not disable firmware desktop mapping or enable sensor reports. Query selected settings first; a measured original USB controller had lizard mode enabled and IMU disabled. A bounded query/write/read-back/restore trial verified a volatile handoff without resetting mappings. Keep the original per connection, verify the applied mode, restore only while it still matches, and fail closed rather than injecting alongside an unverified desktop mode. Keyboard duplication remains an independent acceptance gate until retested. [Evidence and limitations](investigations/controller-priorities-2026-11-11.md).

### Trackball uses contact displacement and a separate momentum clock

Treating pad position as joystick velocity causes continued turning under a stationary finger. Relative pad modes must anchor each contact and integrate finger displacement. Trackball momentum starts on lift, decays by elapsed time, and cancels on renewed contact/focus/source loss. Finger-up reports are status updates, not new lift events: they must neither reset the integration clock nor repeatedly apply the lift timeout. A cadence-equivalence/heartbeat regression caught both conditions before shipping. Both pad preview and runtime share the processor, and mouse mode removes the right-pad joystick-axis contribution to prevent double conversion. [Tests, migration and handoff](investigations/controller-handoff-2026-11-11.md).

### Verify the executable and exclude competing controller owners

Installed/development macOS apps sharing a bundle ID can confuse UI selection, leaving a development process alive when the installed copy quits. Verify the actual running executable, not only LaunchServices/app name. Original-controller mode leases additionally need a kernel lock shared by updated copies; otherwise two sources can overwrite the same recovery receipt or restore while another reader is active. Keep lock FDs close-on-exec and reject symlink paths. [Observed competing-copy incident and handoff](investigations/controller-handoff-2026-11-11.md).

### Estimate trackball launch from motion history, not the last derivative

A real original-controller swipe capture showed the last two contact samples reversing X and jumping Y before touch-up. Ignoring zero touch-up coordinates alone cannot prevent this. Use a robust recent velocity estimate for momentum while keeping direct finger movement immediate; preserve a measured regression fixture and distinguish corrected coast from remaining pre-lift coordinate noise. Touch activation should be an explicit engine gate, with gyro-off holds/native routing still authoritative and immediate neutralization on release. Transient haptic commands need per-pad pacing shared by preview/runtime and bounded bursts rather than persistent controller reconfiguration. [Evidence and acceptance limits](investigations/controller-handoff-2026-11-11.md).

### Separate haptic cadence, texture and notification policy

Strength alone cannot tune trackpad feedback: repeat rate and within-burst spacing affect different sensations. Keep both bounded and shared across preview/runtime, preserve absent-field defaults, and explain that a single test burst cannot demonstrate movement cadence. Gyro touch gating can change state frequently, so provide an independent gyro-note preference without suppressing layer/calibration feedback. User confirmed corrected fling direction, right-pad feedback and touch-only gyro; new pulse feel remains a subjective acceptance check. [Final tests, migration and Undo](investigations/controller-handoff-2026-11-11.md).

### Match feedback to emitted travel, not report frequency

Speed-linked trackpad feedback should integrate cursor-output distance, with a bounded pending pulse and a separate maximum rate. Counting input callbacks makes feel depend on report frequency; accumulating an unbounded backlog produces buzzing after motion ends. Preview must not count the same travel alongside the active desktop source. A per-pad fixed-cadence fallback preserves the earlier option. Tests cover slow/fast travel, bounds, isolation, idle/reset and zero motion; actual new feel remains a hardware acceptance gate. [Installed behavior and Undo](investigations/controller-handoff-2026-11-11.md).

### A wireless receiver slot is not a controller identity

The original 1142 receiver exposes four vendor channels even with the controller off. Select only after a full settings reply and verified capture, keep callbacks per channel, and separate radio disconnect from USB removal. The receiver registry entry survives remote replacements, so do not replay a saved wired-style lease into a later radio session. Bound pending-radio feature retries and move haptic writes off the input thread; serialize restoration after queued output. Actual receiver receipt, mode restore, installed off/on state and user aiming/haptic/typing acceptance are recorded in the [wireless investigation](investigations/steam-wireless-profiles-2026-11-11.md). BLE and native Windows Steam discovery remain separate.

### Keep profile presentation local and control columns consistent

Controller family labels are profile metadata, separate from routing and base-profile mapping inheritance. Falling back to connected hardware for old JSON is safe; copying one legacy hardware-name preference into every profile is not. Shared fixed-width settings slots must align their intrinsic controls to the trailing edge. Installed Display/Performance panels and independent Steam/Overwatch label choices were checked; see [scope, tests and Undo](investigations/settings-profile-labels-2026-11-11.md).

### Verify wireless ownership beyond report receipt

Vendor reports can continue after a receiver-connected controller returns to desktop mode. Stream receipt alone is not proof of capture. Verify the selected settings away from the input loop, recapture only the exact measured baseline with bounded retries, and pause on unknown ownership. Recovery across remote wake requires the remote identity, not the persistent USB receiver slot; store only its digest and verify before restoration. A controlled mode-loss trial failed with timeout-only recovery and passed with the ownership check. Preserve that negative result. [Hardware evidence and remaining typing issue](investigations/steam-wireless-profiles-2026-11-11.md).

### Separate coast errors from direct sensor wobble

A measured vertical swipe rolled laterally at the outer pad boundary before release. Its old coast estimator launched sideways; using the approach window for short boundary dwells corrects that fixture without hard axis locking. Optional per-axis spatial hysteresis addresses tiny direct wobble and preserves zero/raw behavior. User acceptance was with changed X/Y tuning too; do not attribute every improvement to a single filter. [Measured regression and acceptance](investigations/steam-wireless-profiles-2026-11-11.md).

### Separate contact feedback from movement feedback

A pad can confirm finger contact without moving the cursor. Track rising contacts independently for each side, including while feedback is disabled, and emit a finite pulse rather than a held rumble. Share preview/runtime ownership and the existing cancellable radio sender; do not queue a delayed buzz behind motion. Optional strength fields keep old profiles off. User confirmed one pulse on each stationary right-pad touch over the original receiver; full 630-test suite passed. [Evidence, scope and Undo](investigations/steam-wireless-profiles-2026-11-11.md).

### A click that jumps: find out whose click it is first

Three different things moved the game's cursor on a click, and they looked identical. A controller click delivered as a Mac event carried the Mac pointer's position; a physical click during raw capture carried the frozen pointer's position; and the Steam Controller's click was the controller's own built-in trigger action, a real mouse click that no profile had mapped. Before changing delivery code, read the saved profile: if nothing maps that button to a click, the click is the device's. Pads NONE and lizard mode off do not clear the original Steam Controller's built-in *button* actions; those are digital mappings (clear 0x81, defaults 0x85). [Evidence and limits](investigations/controller-click-jump-and-polish-2026-11-11.md).

### Relative input leaves the Mac pointer behind — every reader of it must know

Wine asks the Mac driver for the cursor position after 100 ms without input, and the driver answers with the Mac pointer. Any path that moves Wine's cursor by relative events (controller mouse, raw capture) must tell the driver the pointer is stale, or polling games snap back to it. Keep one flag in the driver, set by whoever posts relative movement and cleared by the first real pointer move, rather than estimating the game's cursor in the helper.

### Smooth by speed, not by dead band

A per-axis dead band steadies a resting finger but must be crossed twice on every change of direction, which users feel as resistance. A low-pass whose cutoff rises with speed removes the same wobble with no distance to push through. Ease movement in for the first 30 ms of a touch: the contact patch is still growing. Match Valve's 15° pad rotation before judging "straightness".

### Don't ask macOS who is in front on every controller report

A CPU sample of the installed app with a Steam Controller profile active (about 15% of a core) showed `NSWorkspace.frontmostApplication` as the largest single cost: the controller runtime asked on every report and every 4 ms tick. The answer is now kept, replaced on app activation and re-asked at most four times a second. Controller mapping still runs on the main thread, so anything slow there delays input; automatic library rescans therefore run only when Nokcandu comes to the front with nothing running, at most once a minute, at background priority, and leave the window alone when nothing changed. Re-measure after installing before claiming a figure.

### "Background" on macOS throttles network and disk too — never apply it to a process the game depends on

`PRIO_DARWIN_BG` is not just a low CPU priority. Putting every store client in the background while a game is in front also throttled the client the game belongs to, which an online game talks to throughout a match. Decide by Wine environment: the game's own client stays normal, others step back. Give wineserver an explicit high QoS; it serves every thread of the game and inherits nothing from them. [Evidence and what is still unconfirmed](investigations/online-play-and-shader-stutter-2026-11-12.md).

### Replay the pad's own reports before tuning filters

"The trackpad hooks and stops mid-move" was not the pad angle (the first guess, rejected by the user). A three-minute passive recording of the right pad (Tools/controller-probe/steam-pad-release.swift `--all-samples`, 1,771 reports at ~8 ms), replayed through `PadSteamTrackpad` under each setting, showed no direction reversals but stalls: with the user's steadiness 1.58 px and default Smoothing 0.4, up to 4 consecutive empty reports mid-swipe and 130 px of lag; with steadiness out, 2 and 56. A per-axis dead band combined with a low-pass catches most small reports. Smoothing now supersedes steadiness. Measure with a recording before changing feel; keep raw recordings out of git.

### A 32-bit game on a 64-bit renderer: watch for host pointers

dgVoodoo2 (32-bit D3D9 → D3D11) on DXMT crashed BF2 reading garbage high addresses, with a 64-bit host pointer next to them on the stack. In WoW64 the 32-bit side must only ever receive memory below 4 GB; a translation layer that hands back host memory fails only when something actually reads it. Check the stack for full 64-bit values before blaming a game or a configuration. [Details](compatibility-fixes.md).

### A client certificate on macOS without the keychain

GameStream hosts authenticate clients by a self-signed certificate. URLSession and Network.framework only take a `SecIdentity`, which on macOS means importing the private key into a keychain (and prompts). Streams does its few HTTPS requests with Mbed TLS instead (`nk_http.c`), keeps the key in a mode-600 file, and pins the host's certificate from pairing. Test the protocol against a fake host before a real one: the PIN exchange (steps 1–4) is plain HTTP and fully checkable in a unit test. [Streams](streams.md).

### One mapping engine, many destinations

Profile passthrough to a stream didn't need a second mapper: `DesktopPad` already turns a controller into controller, key and mouse output. While a stream window is key, it uses the stream's profile and its output sink goes to the stream (`StreamPadRoute`) instead of macOS. Route at the sink, not by copying the engine, so every profile feature (layers, gyro, Steam trackpads, menus) reaches the new destination at once.

### Never hold a lock across a call that waits for your own callback

The stream froze Nokcandu because the decoder held its lock while calling `VTDecompressionSessionDecodeFrame`, and VideoToolbox's output handler (which DecodeFrame can wait for) took the same lock; the display refresh on the main thread then waited forever. `sample <pid>` showed it at once. Give shared output state its own small lock that the callback and the main thread use, and keep the caller's lock off the callback's path. [Streams](streams.md).

### Library major versions change defaults silently

moonlight-common-c's Mbed TLS path assumes 2.x, where `mbedtls_cipher_setup` set PKCS #7 padding. In 3.x it doesn't, so AES-CBC decryption failed on every packet while AES-GCM (no padding) worked. Test a vendored library's call sites against a standard vector, not only the library itself.

### A controller identity is a protocol, not a name

Giving Wine's generic gamepad a Switch Pro's IDs would make it worse: Pro-aware software (SDL's HIDAPI driver) reads the Pro's 0x30 reports and sends it commands, and a generic 15-byte gamepad answers none of them (checked in Wine: "Nintendo Switch Pro Controller", no replies). The working identity imitates the protocol: the Pro's descriptor, its reports, and replies to its handshake, device info and flash reads. Xbox is the exception only because Wine's own reports already have the Xbox layout. Check from the Windows side with a small HID probe, not by reading IDs.

### A test that edits user files must refuse to run without its backup

A restart cleared the scratch folder that held a game's profile backup; the next identity check couldn't restore, and left two test lines in the profile (caught and removed, verified by the original's hash). Test scripts that touch a user's files now copy the file, compare the copy, refuse to start otherwise, and restore in an exit trap. Keep the original's hash somewhere that survives, and check it afterwards.


### A stream window is a "Mac game" for keyboard layouts

Key remapping for streams reuses the Mac-game path (`hidutil` UserKeyMapping with the active marker for crash recovery), keyed on the stream window being key rather than on the frontmost app. The frontmost-app watcher must not restore the mapping while Nokcandu itself is in front with a stream layout applied, or the two fight. [Streams](streams.md).

### Ask for full screen until it happens

`NSWindow.toggleFullScreen` is ignored, with no error, when called right after `showWindow` before the app is active, or during another full-screen transition. Ask, then check `styleMask.contains(.fullScreen)` after the window delegate's transition callbacks and ask again. [Streams](streams.md).

### Name the display, don't inherit it

A window opens on whatever display AppKit picks (the saved frame, or the main screen), and a dummy plug or virtual display counts. Anything sized from "the screen" must choose the display explicitly and store a stable ID (`CGDisplayCreateUUIDFromDisplayID`; `NSScreenNumber` changes between connections), with a fallback when it's gone. [Streams](streams.md).

### One bad value must not empty the controller library

November 13, 2026: every controller profile disappeared. The file was intact (nine profiles), but one binding in "Steam Controller 2" held `pad:lptap`: setting the left trackpad tap to Tap/Hold filled its tap with the input itself, which the encoder wrote and the decoder rejects (a virtual input isn't an output). `profiles()` decoded the whole array with `try?`, so one bad value showed as an empty library; the save guard (refuse to save over an unreadable file) kept the data safe. Fixed centrally: the library and a game's own profile read leniently when strict reading fails (an unknown output becomes Nothing, the original is kept once as `controller-profiles.json.unreadable-backup` / `pad-own.json.unreadable-backup`), saving over a file needs it to read at least leniently (not-JSON still refuses), the encoder writes "none" for any output that wouldn't read back, and Tap/Hold no longer seeds a virtual input's tap with itself (`isVirtual`, not only stick directions). Existing installs recover on the next start with no migration; Undo is the backup file. Tests: `ProfileLibraryResilienceTests`; checked against a copy of the affected file (all nine load).

### Windows commit checks see macOS's growable swap

Wine 11 on macOS reports available commit (`GlobalMemoryStatusEx.ullAvailPageFile`) as free + inactive pages plus unused swap from `vm.swapusage` (`dlls/ntdll/unix/system.c`, `get_performance_info`). macOS swap grows on demand, so a 16 GB Mac with 4 GB of swap (0.7 GB free) reported about 4 GB, and Trackmania warned "free up at least 5.0 GB … page_file/committed memory" (November 13, 2026). Replacing `ntdll.so` is not an option: the engines are Sikarugir builds with msync patches that a stock 11.0 `ntdll.so` lacks. The Wine helper (`Resources/rawmouse/commit-memory.c`, in `nokcandu-rawmouse.dylib`) interposes `sysctl` for `CTL_VM/VM_SWAPUSAGE` only and reports swap able to grow to the size of RAM, never into the last 10 GB of free disk on the swap volume, never less than macOS reports — like Windows' system-managed page file. Physical memory figures are unchanged. Applies to every Wine environment when Nokcandu next starts (it refreshes the helper), and to processes started after that (quit Steam or the launcher first). Undo for one environment: `NOKCANDU_MACOS_SWAP=1`. Test: `Tests/BuildScripts/test_commit_memory.py` (the model, and the built helper injected into a probe). Not yet confirmed in Trackmania.

### Find which half runs the profile before debugging a mapping

A profile runs in two places: Nokcandu (keys, mouse, Mac apps) and Wine's controller driver inside the game's environment (what the game sees as a controller). When a controller-side mapping (gyro as a stick, a remapped trigger) does nothing in a Windows game, first check that the driver half is active: `SharedSupport/nokcandu/pad-active` names the game's pid and map while it's in front, and `pad-status` is written every 2 s while a profile runs there. Missing both meant "Use a Profile Everywhere" had switched the driver off (now fixed; see controller-capabilities). Separately, Wine silently drops rumble for a controller whose SDL driver fails the opening rumble probe; Nokcandu's helper now covers that. [Controller capabilities](controller-capabilities.md).

### One source per controller in games

A profile whose input Nokcandu reads itself (the Steam Controller read directly) and Wine's driver running a profile on the same physical controller through SDL see different inputs, so running both gives the game a controller mapped twice, differently. The rule: whichever half reads the controller is the only one that produces it for the game. For directly read controllers that is Nokcandu, feeding Wine's driver over a socket while the raw device's input is dropped (`source steam`, `PadFeed`). When adding a new input source, decide which half owns it before anything reaches the game. [Controller capabilities](controller-capabilities.md).

### Judge a resting finger against the pad's own noise

November 13, 2026: with the right Steam Controller pad as a trackball (smoothing and steadiness at 0), a still thumb sometimes jiggled the cursor and buzzed the movement haptics continuously; a replug didn't help. A read-only recording of the pad (125 reports/s) showed the readings scattering about 0.003–0.0045 of the pad (single readings up to 0.014) under a still thumb, in steps of 66 and 98 of 65,536, before and after a replug: the pad's normal noise under some thumbs, not a firmware fault. `PadSteamTrackpad` decided "resting" from an instant speed, which that noise kept above `restSpeed`, and the trackball also waited for its own momentum, which the noise kept alive; the raw noise reached the cursor (±8 px per report at the user's sensitivity) and its haptics shook the pad further.

Now: resting is judged on the average position over 80 ms windows (noise averages out, movement doesn't) and the momentum condition is gone. Leaving rest stays instant: one reading beyond `noiseMultiple` (5) times the pad's current scatter (measured around the finger's straight-line path, so the start of a movement doesn't count as noise) releases the cursor on that report. On a quiet pad that is the old 0.008 landing distance, so responsiveness is unchanged; the bar rises only on a noisy pad, capped at 0.03. Movement itself is never averaged: once moving, readings go to the cursor as before. The user asked explicitly for no added latency. Tests replay a 4.4 s slice of the recorded thumb (`RestingThumbRecording`, `RecordedRestingThumbTests`: 5.5 px per report before, under 0.2 now), plus a synthetic wobble, a start-from-rest check (under 50 ms), and the existing feel tests unchanged. Rejected: a fixed higher threshold (delays every small start), and an 80 ms or 4-report average for leaving rest (cost 1–2 reports of each slow start; failed the existing feel tests). Applies to every pad set to trackball or trackpad mouse, in every profile. The user confirmed the cursor holds still under a resting thumb.

### Filter a moving finger by how noisy the pad is, with a cutoff that opens with speed

November 13, 2026: once the resting thumb held still, the cursor still jittered while the thumb moved (same controller and profile: trackball, Smoothing 0). Findings from the same recording (`docs/investigations/data/steam-right-pad-2026-11-13.txt`):

- The scatter around the finger's path is the same moving as resting (per axis about 0.002 x / 0.003 y of the pad at every speed up to 1 pad/s), and its autocorrelation shows no period near the movement haptics' 12.8 Hz. The cursor is still at rest, so no movement haptics fire there: the haptics are not the cause, and the noise is the sensor's, close to white. At the user's sensitivity that is 7–8 px of difference from one report's step to the next.
- White noise can be low-passed; the cost is lag, which matters as a distance. A slow finger can trail by 10 ms and be 1–2 px behind; a swipe can't.

`PadSteamTrackpad` now keeps a running estimate of the pad's noise (`noiseLevel`: the scatter of the last 80 ms around a straight line, averaged; it rises five times slower while the finger moves, since a curving swipe also scatters briefly) and filters movement in proportion: nothing below `quietNoise` (0.0008, so a quiet pad and every earlier synthetic test stay exactly raw), fully from `noisyNoise` (0.002). The filter is One Euro-style: a low-pass at 4 Hz plus 80 Hz per pad-width/s of finger speed, where the speed is counted beyond what the noise alone reads as (60 × the noise level; the pad's noise by itself read as 0.4–0.5 pad/s and would have opened the filter). The Smoothing setting uses the same corrected speed, which is why it used to do little on this pad; whichever of the two is stronger applies. It applies to both pads, trackball and trackpad mouse, every profile, with no setting and nothing to migrate; Undo is not needed for stored data (profiles are untouched).

Measured on the recorded movement (`MovingThumbRecording`, `MovingThumbTests`): step-to-step jitter on slow movement (under 0.5 pad/s) 11.6 → 3.8 px per report; on faster movement 12.4 → 10 px, where each step is 5–35 px. A 2.5 pad/s swipe on an equally noisy synthetic pad is under 12 px (sensitivity 1000; about 2 ms plus noise) behind when it stops, and never overshoots. In the offline comparison the lag was about 9 ms below 0.2 pad/s (1–2 px), 6 ms at 0.2–0.6, 3 ms at 0.6–1.5 and 1 ms above.

Rejected, with numbers in `docs/investigations/steam-pad-moving-jitter-2026-11-13.md`: a plain low-pass (15 Hz: 10 ms at every speed, 26 px behind a swipe); straight-line prediction (least-squares endpoint or alpha-beta: no lag at constant speed but 11–32 px overshoot when a swipe stops); the classic One Euro speed estimate at 1 Hz (slow to open on a swipe: 7 px behind); a median of three. Not tried: the controller's own `SETTING_SMOOTH_ABSOLUTE_MOUSE` (would mean writing an untested setting to the controller). The user confirmed the jiggle is gone and movement is smoother (in a stream; the Mac pointer was still choppy for the separate reason below).

### A posted pointer move isn't visible at once: don't mistake the old position for someone else's move

November 13, 2026: with the trackpad filter in, the user found movement smooth in a stream but choppy on the Mac desktop. A read-only recording of the pad's reports next to the pointer's position polled every 0.5 ms showed the pointer jumping forward by the trackpad's step on each report and back again about 0.6 ms later, leaving only a step of a pixel or so (795 of 2,921 pointer changes came within 2 ms of the one before). The profile also aims with the gyro. `DesktopPad.move` keeps the pointer's exact position between moves and starts afresh from the real position when something else has moved the pointer, which it recognised by the real position being more than 2.5 px from its own. macOS shows a posted move about half a millisecond later, so the gyro's move in the same report read the position from before the trackpad's move, took that for a foreign move whenever the trackpad's step exceeded 2.5 px, and posted from the old position: the trackpad's step was overwritten. A stream takes relative steps, which simply add, so it was smooth.

Now `PadPointerContinuity` (NokcanduCore) also accepts, for 30 ms, the positions macOS may still be showing: the ones Nokcandu posted just before and where the pointer was seen before them. A position first seen longer ago than that no longer counts, so a pointer macOS holds at an edge isn't pushed beyond it; the real mouse, an app warping the pointer and a 0.25 s pause still start afresh. This affects every source that moves the Mac pointer through `DesktopPad.move` (trackpads, gyro, sticks, DualSense touchpad) whenever two of them move in the same few milliseconds or one moves faster than macOS shows it; games fed through Wine's socket and streams were never affected. No settings or stored data change. Tests: `PadPointerContinuityTests` (two sources per report with a 0.6 ms display delay, sub-pixel steps, foreign moves, a held edge). The user confirmed the Mac pointer is smooth with the installed build.

### Gyro drift: a hand is not a table, so correct it from five quiet seconds, silently

November 13, 2026. The user asked for drift to be corrected much sooner ("start after not sensing movement for like 5 seconds"), without notes on screen all the time, and reported that a good calibration was sometimes lost again. How it worked: an automatic measurement needed the controller "put down" (readings changing by under 1 degree/s between reports for 1.5 s), averaged the next 1.5 s, ran at most every 30 s, and showed a progress bar and "Gyro calibrated" each time; the resting reading lived in the profile engine and was discarded whenever the engine was rebuilt.

Evidence: 300 s of the user's Steam Controller, hand-held (`docs/investigations/data/steam-pad-gyro-in-hand-2026-11-13.txt`, gyro columns × 2000/32768 = degrees/s). The true drift was about (+0.4, −0.6, +0.3). In a calm hand the change between reports stayed under 1 degree/s for seconds at a time, so the hand passed for "put down", while 2 s averages wandered about 1 degree/s from the true drift (one calm 2 s window averaged +1.35 on x). So the quick measurement itself replaced good readings with worse ones: the "randomly lost" calibration. A 3 s rule tried offline accepted a window 1.3 degrees/s off; a 5 s stretch whose half-second averages agree within 1.2 degrees/s accepted only good values (one in that recording, within 0.1–0.2 of the others).

Now, in the shared engine (`padengine.c`, so also inside Windows games):
- **Quiet tracking**: whenever nothing has moved for 5 s (in the hand or put down), the average of those 5 s becomes the resting reading, and again for each further 5 s. "Nothing moved": every reading within 8 degrees/s of the current resting reading and within 5 of the stretch's average, no jump of 6 between reports, the half-second averages within 1.2 of each other on every axis, and gravity (the accelerometer, now always passed to the engine) within 2° of where it pointed at the start, which tells a slow steady tip from drift.
- The quick put-down measurement only gives the first resting reading; it no longer replaces one.
- Automatic measurements show nothing while they run, and a note only for the first one or a correction of 1 degree/s or more. The existing setting still turns those off; a calibration you ask for shows as before.
- `DesktopPad` carries the resting reading over when the engine is rebuilt (`pe_calibration_get`/`pe_calibration_set`): another profile for the app in front, an edited profile, a stream starting.

Known limit: a perfectly even turn about the vertical (which gravity can't show), under 8 degrees/s for a full 5 s, would be taken for drift; the next quiet 5 s corrects it. A Windows game's own engine (controllers not read by Nokcandu itself) still starts without a resting reading each time the game starts. Tests: `GyroQuietCalibrationTests` (hand tremor with changed drift corrected in 5 s and announced once, a small correction silent, a calm 3.5 s slow turn ignored, uneven and tipping turns ignored, first measurement and carry-over, automatic off), `PadCalibrationKindTests` updated. No stored data changes; profiles' "automatic calibration" switch keeps its meaning. Not yet confirmed by the user.

Added the same evening: once there is a resting reading, the quick put-down measurement may still replace it (after 1 s of stillness, at most every 5 s), but only if every reading of its 1.5 s stayed within 1 degree/s (`TABLE_RANGE`; the calmest recorded 2 s in the hand spanned 1.6–2 per axis) and gravity didn't move by 2°. So a controller put down is corrected in about 3 s and one held still in about 5. An existing test (`GyroDriftRecoveryTests`: a bad first measurement corrected by the next rest) failed without this.

### A window switch lets go of outputs, not of the controller's own state

November 13, 2026: "why does my controller's layer change when I switch windows?" On a change of the app in front, `DesktopPad` called `pe_release_all`, which ends everything held or toggled into the old app and also cleared the layer switched on with a layer toggle and the gyro's on/off toggle. Now a focus change (and a change of capture target) calls `pe_release_outputs`: the same release, but toggled layers and the gyro toggle stay; a held layer button is picked up again from the next report as before. `pe_release_all` (sleep, no controller left, engine teardown) still resets them. If the app in front has a different profile, the engine is rebuilt and starts on its base layer, as before. Also: `PadSteamTrackpad.reset()` (called on each focus change) keeps the pad's measured noise level, so the first second after a window switch is filtered too. Test: `PadFocusKeepsLayerTests`. Not yet confirmed by the user.

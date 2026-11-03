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

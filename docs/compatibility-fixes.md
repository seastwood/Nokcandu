# Compatibility components

Components are usually opt-in per managed Windows app. Dedicated launcher setup can install reviewed components automatically, as documented for EA and Ubisoft below. Generic components and shared infrastructure are separate from game- or launcher-specific recipes. See the [documentation index](index.md) and [current engineering learnings](engineering-learnings.md) for confirmed results and unresolved investigations.

| Profile ID | Files/settings owned | Source |
| --- | --- | --- |
| `bundled-vc-runtime` | Selects matching-architecture C++ libraries already beside the program; individual native/builtin rules | App-bundled libraries; no download |
| `cross-process-windows` | `DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN=1`, with independent Undo | Nokcandu settings; requires DXMT |
| `ubisoft-browser` | Exact-version browser library edit, `--in-process-gpu`, DXMT cross-process setting; original backed up | Built-in verified Ubisoft-only compatibility definition |
| `openua-display` | Allowlisted OpenUA `NUCLEUS.INI` display/menu settings | Built-in OpenUA-only recipe |
| `shader-compiler-47` | Matching-architecture `d3dcompiler_47.dll` beside the selected program, native/builtin override; independent Undo | Microsoft Windows SDK CABs, SHA-256 pinned |
| `directx9-extras` | Matching-architecture `d3dx9_43.dll`, `d3dcompiler_43.dll` beside the selected program; individual native/builtin DLL rules | Microsoft June 2010 DirectX redistributable, SHA-256 checked |
| `d3d8to9` | Local `d3d8.dll`, individual d3d8/d3d9 rules, `legacyD3D9` flag selecting existing `renderer/dxvk/wine` | crosire/d3d8to9 v1.16.0, SHA-256 checked |
| `cursor-visibility` | Opt-in state flag; native helper uses a transparent cursor only while Wine requests it hidden, restoring Wine cursor updates for menus and focus changes. Raw mouse input is independent. | Nokcandu native helper; validated runtime layout |
| `borderless` | `C:\nokcandu\borderless\launcher.exe` and `window.dll`, matching program architecture; `borderless` flag | Nokcandu C sources built with pinned Zig |

The generic components leave the selected game executable unchanged. The launcher wraps it only when borderless is enabled; its working directory and original arguments are preserved. The injected window helper stays inside the launched process, ignores minimized, owned and tool windows, and does not change the display mode or force the window above other apps. It follows restarts of the same executable, not arbitrary launcher children. This is a compatibility option, not a guarantee for every game.

`CompatibilityFixes` keeps installation manifests and conflict-aware file journals inside the game's state directory. Original files are backed up before replacement. Network downloads and extraction finish before game files change; the game and settings are rechecked before committing. A per-app reservation prevents simultaneous component operations. Interrupted installations retain an Undo record. Undo validates owned files before touching settings; it restores only that component's DLL rules and switches, preserving other components and unrelated settings. An external edit blocks Undo rather than being overwritten.

Profiles name built-in IDs only. Preview lists component installs and unavailable components. Installed component settings remain active when applying/undoing a settings profile; remove them with their own Undo. A program change is blocked until its components are removed. Shared Steam/Battle.net/other launcher environments need explicit per-program routing before support can be enabled.

BF1942 display support is a separate built-in recipe (`BF1942DisplayFix`), not a community fix ID. The Display panel distinguishes the Mac's resolution, window style, and the game's internal resolution. Game-resolution edits touch only allowlisted `.con` commands in known profile files. Missing defaults are created, unrelated content and line endings are preserved, and linked paths that escape the installation are rejected, including paths to files that do not exist yet.

The recommended action checks `BF1942.exe` against locally verified fingerprints, creates `BF1942-Nokcandu.exe` beside it, sets 1280 × 800 windowed gameplay, keeps the Mac at desktop resolution, and installs the existing borderless component when needed. The copy changes the two hardcoded menu dimensions and the mod-restart filename (five bytes total). `BF194N.exe` is an identical verified copy with the same-length name expected by the restart code. Activating a mod keeps the game’s own restart arguments and working directory, but starts the corrected copy again. The original EXE is never written, no game binary is distributed, and an unknown fingerprint disables menu correction. A local `bf1942MenuCopy` launcher switch redirects to the checked copy without replacing the selected program's identity. Source and copy are checked at launch, and the display watcher follows the actual copy.

A private receipt and file journal allow repeated resolution changes to undo back to the original settings. Recovery receipts precede mutation. Undo validates files before changes, restores only owned settings, removes borderless only if this recipe installed it, and keeps separately installed components. Schema 2 profiles reference the built-in display recipe and supported resolution, while its local execution flag and patch bytes are never shared. Profile Undo checkpoints restore video files and the previous private Undo ledger. Changing the selected program requires Undo first. Older manually created BF1942 wrapper programs can be normalized when no compatibility components are bound to them; Undo retains their original selection.

Known source SHA-256: `3a3eab9af4ad711f9faf6a17d8e31a3bacbbace99fe8356a700e1071c143cd7f`. Known corrected SHA-256: `3b8033a58197ee844f4c4238b0bb873d1fcc6ba0a0f918b4fb247c9ac1ee01f2`. These identify the files tested on this Mac, not every BF1942 edition. The recipe never downloads patches or accepts community-supplied offsets/fingerprints.

Validation: Swift unit tests cover grouped DLL rules, component references, old settings decoding, launcher quoting, conflict refusal, file restoration and independent component Undo. Both Windows architectures were tested against an isolated Win32 probe: window bounds matched its monitor and quoted arguments survived forwarding. Microsoft-hosted extraction was checked with the bundled tool. These checks do not establish gameplay compatibility for all games.

Private fix journals retain their app-relative origin so Undo follows a whole-app move. BF1942 settings operations use logical C: paths after validating their physical target, retaining one consistent file history when managed game files move to a separate drive.

The native helper also watches confinement for the installed borderless component. It checks the known Wine confinement handler, active owning game window, and Wine's own coordinate conversion. If the actual native rectangle differs from Wine's projected request after a resize, it resubmits that same request. It does not synthesize focus events, move the pointer, enable raw capture, or expand beyond the requested region. Matching rectangles are untouched, and repeated identical failed attempts are suppressed. Runtime verification caught a stale 989 × 756 native region while Wine requested 1468 × 954; the refresh restored the requested region without Cmd-Tab.


### OpenUA: invisible window and tiny menu on Wine/macOS

Observed with the user-provided OpenUA standalone package (UA_source.exe, build 2025-03-09) and Sikarugir Wine 10.0_8 on Apple Silicon. The program reached its menu and played music but its window was transparent. Setting `gfx.vbo = off` in the game's `NUCLEUS.INI` made the intro and menu render. OpenUA's source reads this setting before `System::Init(!gfxVbo)`; the old path requests OpenGL 2.1 instead of a 3.1 compatibility context. This is a game-specific setting, not a global Wine rendering switch.

The menu then appeared with very small text: the original `DATA/world.ini` requested `shell_default_res = 640_480`, but that mode was absent from the reported display modes, and `ENV/vid.def` showed 2560 x 1600. Adding `gfx.custommodes = 640x480,800x600,1024x768,1280x800` in `NUCLEUS.INI` preserved the original menu mode. With `menu.windowed = off`, the menu rendered fullscreen with readable text and `ENV/vid.def` reported 640 x 480. The windowed-only experiment did not resolve the rendering failure. Menu and intro rendering are verified; mission performance still needs a play test. Back up the game's original INI before editing. These settings are now available through the built-in `openua-display` component recipe in Display and Fixes. The recipe is detected only for UA_source.exe importing OpenGL, with NUCLEUS.INI, DATA/world.ini and LEVELS beside it. It changes three allowlisted INI keys, keeps other settings and extra resolutions, journals the original file for conflict-aware Undo, and is included in saved/shared profiles. Applying it is an explicit user action or a previewed shared-profile action; importing a game does not silently rewrite its settings.

Upstream references: https://github.com/Marisa-Chan/UA_source/blob/master/src/main.cpp and https://github.com/Marisa-Chan/UA_source/blob/master/src/system/system.cpp .


### Shared launch infrastructure: native tools versus Wine helpers

Nokcandu’s x86_64 helper library belongs in Wine, not in native ARM64 utilities. Launcher generation uses `HelperPatch.scopeWineLibrary` to keep its path in a shell variable and pass `DYLD_INSERT_LIBRARIES` on Wine commands only. The registry handoff still supplies that path to Wine child processes. Built-in recipe blocks, general game launchers and shared Steam use the same scoping logic. Existing recognised helper blocks and hash-verified generated launchers migrate centrally; running games and manually edited scripts are skipped. `GameLauncher.launch` and `preflight` request the same migration so a failed startup does not depend on background maintenance having completed.

The regression was observed in Zero Hour’s ARM64 Python launcher-extraction step, which aborted when a globally exported Intel dylib was loaded. Do not work around this with per-game mouse settings, an Intel Python requirement or changes to the game’s tested renderer. Regression tests check native/Wine environment separation, `exec` launches, old/new fingerprints, generated Steam/custom scripts, and preservation of manual edits.


### Settings ownership and accessible recovery

`ChangeJournal.writeSettings` and `TextSettings` provide shared command/key ownership for settings-only recipes. Apply reads the game's current file and updates allowlisted fields. Undo restores those fields from the original backup while preserving unrelated current lines, newline style and UTF-8/Latin-1 encoding. The complete pre-Undo file is retained in a recovery ledger. BF1942 display settings and OpenUA use this mechanism, including migration of older receipts. Executable/DLL writes keep strict full-file fingerprints. Unrecognisable or missing settings files require an explicit saved-version restore rather than guessed edits.

Display and Health expose Settings Backups with dates, original file locations, Show in Finder and Restore. Restoration verifies the saved bytes, is limited to the selected game's settings paths, and backs up the current file first. Both private component journals and the game's shared journal are listed, including known Documents settings for built-in recipes.

BF1942 mod-switch reproduction showed the active DS profile at 2560×1600, **16-bit colour**, while the display receipt still recorded 1280×800. The game restarts its original BF1942.exe when activating mods. The repair applies the selected gameplay mode in 32-bit colour to the base game's profiles (shared by these mods). The generic borderless supervisor accepts an optional alternate restart executable, so a verified menu copy can hand off to another game process without losing window presentation. Owned bundled helper files and hash-verified generated launchers update centrally while the game is closed. Verify in-game mod switching separately from initial launch.

The earlier alternate-process handoff alone did not resolve mod activation: the original executable still rejected its menu video mode. Existing owned menu copies now upgrade automatically while closed, without resetting resolution or other settings. Both corrected files are journaled, fingerprint checked at launch, and covered by Undo; edited files are left alone. The original executable remains unchanged. Mod-switch runtime verification is tracked separately from automated tests.

**Complete BF1942 setup:** Display → Apply Recommended BF1942 Setup previews and installs missing `directx9-extras`, `d3d8to9` and `borderless` through the shared component installers, selects Older 3D, then applies the verified menu/mod restart display recipe. Existing display resolution is retained; new setups use 1280×800. Unknown executables are rejected before downloads or mutation. Completed components retain their own Undo and profile IDs; retry skips installed components if a later step fails. This is explicit per-game setup, never a global default for other games. The shader crash observed after successful mod activation was caused by absent native shader DLLs and overrides, not the mod-restart filename correction.

Runtime verification (2026-10-28): after installing DirectX 9 extras, the restarted `BF194N.exe +game DesertCombat +restart 1` process mapped the game-local Microsoft `d3dx9_43.dll`; the user confirmed the Desert Combat match loads successfully.

## EA app installation

EA app 13.813.1.6327's bootstrapper fails with INST-14-1627 under the tested Wine 10 engine. EA's signed MSI supports `EAX_DISABLE_SYMLINKS=1`; running the complete MSI with that option, plus the bootstrapper's required package-cache and uninstall metadata, completed with exit 0 in an isolated prefix. Nokcandu now extracts the current package URL, size, SHA-1 and version/provider metadata from the official WiX bootstrapper, accepts only EA's official payload location, verifies the downloaded package, and installs it without modifying either executable. No engine change or unverified older installer is used. The raw Wine 11 builds tested here could not initialize a Windows prefix on this Mac and are not selected as a workaround.

The EA-specific route is used for Store → Set up EA app and for a manually selected EAappInstaller.exe. Successful setup selects EADesktop.exe automatically, and verifies that a valid PE executable exists before advancing. Failed setup remains retryable. Detailed MSI output is retained at Contents/SharedSupport/Logs/ea-install.log. Shared `WindowsMSI.command` handles MSI property value quoting through a Windows batch file, rejecting command expansion/metacharacters; the corrected quoting is available to other component installers. General game installation behavior is unchanged.

Installer success does not establish sign-in or game compatibility. Verify the client window and sign-in separately.

### EA client startup, after installation

The installed EA client initially waited before creating a window. A Wine debugger backtrace of its main thread identified a wait in Wine's builtin msvcp140; mapped-file inspection confirmed Wine's C++ family was selected despite EA shipping native Microsoft equivalents. Selecting the matching game-local 140-series libraries got the client to browser initialization. Combining those libraries with DXMT and `DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN=1` got EA's log to `Login page load succeeded, HttpStatus:[200]`. Software Qt/browser flags alone did not fix startup. Visual sign-in verification is separate.

Two shared optional components capture these settings: `bundled-vc-runtime` selects only valid, matching-architecture C++ DLLs already beside the selected program, and `cross-process-windows` enables DXMT's cross-process window support. Neither downloads or patches libraries. Components have independent Undo, preserve unrelated environment rules, and are included in profiles. The EA installer chooses DXMT and applies these components while building a new launcher; other games opt in through Fixes. Existing user-selected graphics modes are not changed globally.

EA visual verification: loading the login URL did not prove the page was drawn. The user confirmed that Fullscreen (Borderless) makes the EA pages render and signed in successfully. Fresh EA setup now installs the existing shared borderless component alongside the bundled C++ and DXMT window components. Standard DXMT window presentation, software-browser attempts, upstream DXVK, and the alternate-engine experiments were not sufficient by themselves. Do not replace working borderless settings with those experiments.

Launcher-host detection now checks the selected host app's own generated-launcher lock and process path, instead of accepting any EA/Ubisoft process on the Mac. Separate Wine environments share localhost ports; an isolated test EA copy held 3216 and was closed before retesting the user's working launcher.

EA icon rendering diagnosis: the browser reported `isinf` missing while compiling a `vs_5_0` shader. A standalone D3DCompile probe reproduced Wine’s E5005 failure; the exact same HLSL succeeds with Microsoft’s compiler. `shader-compiler-47` is a shared optional component for affected games and browsers. Fresh EA setup installs it along with borderless. It does not change other games automatically, touch Wine’s system libraries, or modify executable files.

EA background-helper regression: a clean-prefix EAGEP test completed initialization. Removing the inherited `DYLD_INSERT_LIBRARIES` value for a controlled process in the real prefix also let it connect; merely clearing the Unix launch environment had not removed the registry-propagated helper. The native helper now excludes Windows services, EA elevation/local-host/background workers and browser workers before creating a GameApp or registering input/display hooks. Its interposed audio, scheduling and frame-limit functions are also inactive for those processes. A real EAGEP run using the new library connected to EA and shut down cleanly. Existing apps receive the new library through RawMouse.refreshLibraries’s hash-based migration; foreground game settings and capture defaults are unchanged. Populous’s temporary RUNASADMIN removal is being restored for verification of the shared fix.

EA’s icons were visually verified after installing `shader-compiler-47`: navigation arrows, cart, bell, friends controls and rating artwork now draw. Populous progressed to a running DOSBox process after the normal-privilege test, but its visible gameplay and a full elevated launch with the new helper still need confirmation. BC2 downloads were present but EA refused Touchup.exe at its incomplete signing chain check. Its original downloaded setup completed when invoked directly; see the shared recovery action below. No certificate trust has been added or signature verification disabled. Game launch/play testing is separate from setup completion.


### EA final game setup recovery

On any Nokcandu EA host, **EA app Games → Finish EA Game Setup…** runs the selected download's original `__Installer/Touchup.exe`, using EA's supplied command from `installerdata.xml`: `install -locale … -installPath … -autologging`. This is an explicit recovery action after an EA download fails during final installation, not automatic execution of folders or downloaded profile code. New and existing EA hosts use the same code. Select the game folder downloaded by EA; keep that game closed. EA itself can remain open. Setup progress and a Show Setup Log action are provided; the log is inside the host app's `Contents/SharedSupport/Logs/ea-setup-<game>.log`. Reopen EA if it still displays its previous error, then Refresh the games list.

The recovery validates the fixed setup command, program type, matching package files, locale and mapped Windows path. It rejects escaping setup links, unknown executable/command metadata and files changed after selection. It doesn't replace binaries, add trusted certificates, modify EA's verifier or mark an unrun installer successful. It runs the user's selected Windows setup package just as the existing Run Program feature does.

BC2's original setup installed its DirectX/VC2005 prerequisites and Windows game/uninstall registration with exit 0. Repeating Touchup exposed a second failure: Wine's `IGameExplorer2` update returned `80070002`. Setting `gameux=` only in the setup process enables Touchup's own older registry fallback and makes repeat setup succeed. Recovery preserves other DLL rules and never writes this override into the game's config or prefix registry. The real-package E2E test accepts explicit host/game paths via environment variables so this can be verified with other authorized EA downloads. Successful installation is not a gameplay claim.


## EA game settings and setup recovery

EA shortcuts with a selected Windows program now keep graphics, launch arguments and performance in their own app state. They use the host's Windows environment but retain separate logs and a live game lock. Known generated launchers migrate automatically; edited scripts stay untouched. Windows tools resolve the actual host. Hosted profiles capture/apply/undo per-game graphics, arguments, safe environment settings and performance without changing the shared client's raw mouse or audio settings.

EA games also have optional Fullscreen (Borderless). Helpers are stored by architecture under `C:\nokcandu\borderless\x86` and `x86_64`, so a 32-bit game cannot replace the 64-bit EA client's helper. Hash records preserve manually edited helpers. The game must be windowed internally. The BC2-only recommendation uses DirectX 9 and the game’s own fullscreen mode at the current desktop size, without the helper. Resizing BC2’s window with the generic helper leaves a constant menu-pointer offset; changing DPI did not fix it and that experiment was reverted. The user confirmed native fullscreen aligns menu clicks and survives Command-Tab. `gameDisplay.recipe = bfbc2-desktop` uses the portable `[0, 0]` desktop sentinel; applying on another Mac resolves its own current desktop size. The older `bfbc2` windowed recipe remains supported. Undo merges only owned values and preserves later unrelated edits.

EA's DXMT client additionally exposes the tested DX9 renderer to older child games. Some activation-protected games are relaunched by EA and lose shortcut environment settings. The client's DXMT renderer and explicit DLL overrides remain intact. Bundled matching-architecture shader helper libraries beside a directly launched game are selected without downloading replacements.

`Finish EA Game Setup` discovers contained original DLC packages (bounded depth, no directory-link traversal), accepts the exact EA `pdlcinstall` command as well as base-game `install`, and passes the base install root to DLC setup. Each package has its own result/log; setup completion does not forge EA download-manager status. Verified on ten Dragon Age add-ons.

A PhysX import in downloaded EA game files triggers installation of NVIDIA's official PhysX runtime when adding/recovering the game. Other Windows games can install it from Windows Runtime. The installer is SHA-256 pinned, installs only into that Wine environment, and verifies the 32-bit loader plus runtime engine. The dependency check uses PE imports, not a hardcoded game title. Dragon Age's NxCharacter.dll was present but depended on this missing runtime; the user confirmed the game becomes visible after installation.

Shared process output collection uses bounded nonblocking reads. It does not wait for EOF from descendants after the original installer exits, and avoids macOS Foundation EOF callbacks spinning in `waitUntilExit`. Timeout and cancellation stop the launched process. Restart recovery stops the selected Wine server, waits for shutdown and the launcher supervisor, and only then clears its locks/reopens EA. It closes all games in that environment and is labeled accordingly. It does not promise that every EA title or DRM system works in Wine.

Hosted games with a selected Windows program keep mouse settings in each hosted game's state as well. The native helper resolves a program-to-settings table at process startup (exact paths first, basename fallback only when unique), so EA activation relaunches still find the game's own flag. Existing shared Steam behavior remains unchanged. A hosted game's missing flag means Raw Mouse Capture is off, even if the launcher has it enabled. The existing half-second watcher keeps toggling/speed changes live; hosted profiles capture and restore these per-game values.

Storage and Show Game Folder for hosted games use the store-registered install root, falling back to the program directory only when registration is missing. This fixes DAO counting only bin_ship (about 198 MB) instead of its full external installation (about 63 GB). No files are moved or removed.

Hosted launchers must explicitly scope the native helper to the Wine invocation, using the same shared `HelperPatch` block as standalone games. A saved host registry path does not load an Intel macOS library into the initial Unix Wine process. This omission was confirmed with BC2’s live memory mappings: no native helper was loaded, so neither raw input nor audio-thread priority support could run. Hosted launchers now load it explicitly, while native shell utilities stay uninjected. Fingerprinted launcher migration also runs immediately before launch/preflight, so a previously running game cannot miss its pending upgrade.

EA installer elevation repair is shared infrastructure: a bundled Windows helper queries registered Electronic Arts game install roots and removes only standalone `RUNASADMIN` tokens from existing programs under those roots. Other flags and unrelated programs stay intact. Before changing a value it saves the original under `HKCU\Software\Nokcandu\CompatibilityBackups` (subkeys identify the original hive/view); a failed backup prevents the change. It runs on EA startup, hosted game startup, and successful manual setup recovery. One prefix-local watcher also repairs flags restored by EA install/repair while the client is open, and exits after EA closes. Generated launchers migrate by fingerprint; manually edited launchers stay intact. No macOS administrator privileges, game binary edits or certificate changes are involved.

Regression checks: the helper repaired Populous after its installer flags returned; a simulated restored flag was removed again automatically; a temporary registered-game fixture retained `WIN7RTM` and `HIGHDPIAWARE`, while an unrelated program retained its elevation flag. User confirmed Populous opens without its permission prompt. BC2 audio helper loading was verified in the actual game process, including sound-thread priority messages; audio quality still needs gameplay confirmation.

Shared restart checks now inspect native process executable paths as well as `wineserver`: EA was observed leaving a live game after its server had exited. Restart terminates survivors only in the selected app’s private Wine engine/GameApp paths, rechecks ownership before each signal, waits for exit, and then applies settings. A surviving native program also triggers the restart confirmation even when the server wait returns immediately. Tests cover a real orphaned fixture process and an unrelated process that must survive.

Open audio investigation (BC2/DAO): user reports clean menu audio but repeated/delayed gameplay sounds. Buffers 10/20/40 ms, confirmed native-helper loading/priority, a checksum-verified official DSOAL r697 test, the engine’s original Mac audio driver, and disabling extra Wine synchronization did not resolve BC2. Test DSOAL files were removed, normal synchronization and Nokcandu’s normal audio driver restored. Explicit `SpeakerCount=2` also did not fix it. Gameplay warning logs showed repeated `IDirectSoundBufferImpl_Lock` mixing-position overwrites; no continuing buffer-underrun warnings. The active MacBook speakers were at 44.1 kHz; 48 kHz with EA’s overlay disabled also failed, and the original 44.1 kHz rate was restored. BC2’s sound-mastering profile 2 with medium quality also failed; the original profile/quality were restored. The older bundled renderer made graphics worse and did not fix audio, so its per-game override was removed. A separate checksum-verified Wine 11.0 r1 scratch test reproduced its earlier failure to run `cmd /c ver`; EA stayed on Wine 10. BC2’s native fullscreen still needs a stable launch/re-entry fix; a smaller window is being used for audio testing. Do not promote unsuccessful experiments to defaults.

Engine updates also reset the saved original audio driver, retain it in the engine rollback record, and restore it with that engine. Buffer adjustments must never reuse an original driver from a different engine. Tests cover existing/missing baselines and reject hosted shortcuts as engine hosts. The DirectX 8 fix description now says “bundled compatibility renderer” rather than assuming a version: the installed older renderer reported v1.10.3-async in the actual test, despite the old UI calling it 2.3.

A subsequent Wine-only endpoint-filter test hid both virtual Jump Desktop audio devices (confirmed in the game log) but audio still repeated. The temporary helper and environment flag were removed and the normal helper restored. All audio experiments are reverted; BC2 remains in a smaller window for continued diagnosis. A recording with an actual audio track is needed to measure repeat timing; the supplied MOV contained video only.

### Installer handoff and Ubisoft browser workers (October 29, 2026)

The general EXE/MSI setup stage now opens Windows setup without `start /wait`. It returns to the user handoff instead of waiting indefinitely for an application the installer leaves running. After finishing and closing setup, the user presses Continue; Nokcandu checks for installed programs before advancing to program selection and its later self-check. Failed launches reset the handoff marker so Retry opens setup again. This applies to general Windows installers, not only Ubisoft. EA's dedicated verified MSI route remains separate.

Ubisoft's `UplayWebCore`, service, elevation, extension and crash-report workers are now excluded from the native game-app/input/window helper, alongside the existing EA and Steam browser/service exclusions. Normal `upc.exe` and actual games retain their normal helper behavior. The shared helper refresh distributes this correction to existing apps as well as new installations.

Regression verification: 167 tests, five optional tests skipped, no failures; signed release build and installed-app signature verification passed. The installer test verifies that no `/wait` is sent, an empty installation cannot advance, and installed program files permit Continue. The native process-role test covers Ubisoft worker paths/case variations while retaining the foreground launcher.

Historical intermediate results, superseded by [the verified resolution](#ubisoft-connect-verified-resolution-october-29-2026): Ubisoft's blank/transparent page was still unresolved at this checkpoint. The installed Wine 10 environment reported DXMT's unsupported cross-process swapchain, then a missing Metal surface after enabling the existing optional cross-process fix. That fix alone did not restore rendering. Browser flags `--in-process-gpu --disable-gpu`, including a reversible exact-version CEF command-line compatibility experiment, Compatibility graphics and Apple Metal also did not restore the page. Removing the native helper did not fix it. Those unsuccessful settings and the CEF file experiment were restored at that checkpoint. The verified official Sikarugir WineCX24.0.7_7 engine passed a fresh-prefix Windows command test, but its disposable client comparison did not establish a working page; the installed engine was retained. The later successful component is described below.

Research reference: [trackmania-mac's implementation notes](https://github.com/Pab450/trackmania-mac#how-it-works). Its reported success is not treated as verification on this Mac.

### Preserve renderer rules when adding DLL fixes (October 29, 2026)

Generated standalone launchers used to export the selected renderer's DLL rules and then replace the entire variable with a component's `WINEDLLOVERRIDES` value. A shader/runtime fix could therefore discard unrelated graphics rules. Graphics presets now expose one set of defaults and merge extra rules by DLL name, with explicit user/component rules taking precedence. Shared-launcher game scripts use the same merged map rather than relying on duplicate Wine rules. Saved configuration values are unchanged; hash-verified generated scripts migrate through the existing refresh path, preserving manual launcher edits and leaving running games alone.

Tests execute the generated shell exports for all six graphics modes, verify shader/DirectSound additions retain unrelated renderer rules, and verify explicit DLL choices override defaults in both standalone and hosted scripts. Full suite: 169 tests, five optional skips, zero failures. Signed release build passed.

Further Ubisoft tests: an isolated WineCX engine comparison and software composition did not establish a working page. One later comparison did not start because diagnostic registry commands left its private server running with a different msync setting; this was identified and cleared before retrying. Original installed browser resources exactly match the official installer. The normal-engine/DXMT comparison with the GPU in the main browser process was subsequently verified visually; see the resolution below. The DLL-rule merge itself is independent of the later Ubisoft-only browser component.

### Ubisoft Connect: verified resolution (October 29, 2026)

The normal installed Ubisoft app now renders its sign-in form, verified directly with a window screenshot after applying the standard component. The successful setup keeps Wine 10, uses DXMT with the corrected merged DLL rules, enables cross-process swapchains, and runs CEF's GPU in the main browser process (`--in-process-gpu`, without disabling the GPU). Ubisoft sets CEF's `command_line_args_disabled`; the built-in `ubisoft-browser` component permits launch switches only in the exactly verified 32-bit CEF 135 browser build. Both the original and resulting full-file SHA-256 values are pinned in `UbisoftBrowser.swift`. No sandbox or certificate bypass is used, and neither the alternate engine nor software-rendering experiments are installed.

The component uses the normal change journal: the original browser file is backed up, settings are recorded, and Undo restores the file and owned launch switch while preserving unrelated argument changes. It appears only for Ubisoft Connect and can be referenced by saved/shared profiles. A normal Finder launch also repairs an update that restores this same verified official browser build; unknown hashes, symlinks and changes during repair are refused. An unverified later Ubisoft browser requires an updated compatibility definition, rather than guessing patch locations.

Fresh Store → Ubisoft Connect setup selects the actual installed `upc.exe`, chooses DXMT, closes the client left running by setup, and installs the Microsoft shader compiler and Ubisoft browser component. The generic installer handoff, renderer-rule merging and browser-worker helper exclusions remain shared infrastructure fixes. Existing Ubisoft apps can install the component under Fixes; this Mac's existing launcher was updated through that same component API.

Validation: 173 tests completed with five unrelated optional skips and no failures, including an end-to-end test using official local browser bytes. Coverage includes install, normal-launch repair, exact-hash rejection, changed-file preservation, Undo, argument preservation, profile export, Ubisoft-only visibility and fresh-setup program/backend selection. The release build and installed app signature verification passed. Both the disposable comparison and the normal installed app were visually confirmed to draw the sign-in form; account sign-in and Ubisoft gameplay have not been tested here.

### Shared Media Foundation loading and selected-game restart (October 29, 2026)

`WineEnvironment` now includes `Contents/Frameworks/GStreamer.framework/Versions/1.0/lib` alongside `Contents/Frameworks` and `/usr/lib`. Generated custom, Steam, hosted, Battle.net and recipe launchers use the same path as native Wine tools, installers and winetricks. Winetricks also inherits the standard Wine synchronization environment. This addresses the observed Media Foundation parser-loading failure in Chrono Trigger; it installs no codec and changes no game asset. Recognized generated launchers migrate through their existing checks; manual scripts are preserved. The known recipe fingerprint normalizes only this managed path addition. Steam's active configuration fingerprint includes the path, ensuring an old running host requests a restart.

After an Apply and Restart edit succeeds, `WineTools.applySettings` opens the selected game's normal launcher rather than only reopening its host. Error recovery retains host-only reopening. Tests cover success/error targets and environment consistency; 182 tests passed with six optional skips, and the signed release build passed. The controlled media launch was user-confirmed. See [the dated investigation](investigations/chrono-trigger-media-2026-10-29.md) for evidence and remaining end-to-end verification boundaries. Neither change is a claim that all media formats, games or the open BC2/DAO audio issue now work.

### Shared engine graphics detection (October 29, 2026)

The earlier Chrono Trigger direct-launch success did not verify its normal saved DXVK mode. A later normal launch reached media presentation but failed Vulkan surface creation. The user confirmed normal Steam startup after saving Compatibility. Main-program-only detection had missed OpenGL in the imported local Cocos2d engine. `PEFile.inspectWithLoadedDLLs` now walks actual local import dependencies (64 entries, 64 MiB per file, 256 MiB total), checks architecture and resolved directory, handles cycles and rejects ambiguous names. Executable graphics imports/runtime names retain precedence. General/Steam installation, hosted defaults and Recommended Settings share this evidence. Saved choices remain intact; OpenGL-only recommendations respect a mode marked as working. This is a detection improvement, not an automatic global renderer replacement. The media-library-path correction remains necessary and independent. Detailed evidence and limitations are in the [Chrono investigation follow-up](investigations/chrono-trigger-media-2026-10-29.md#follow-up-normal-launch-black-screen-and-engine-detection).

## Wine 11 virtual-screen launcher rendering — October 30, 2026

The shared Wine 11.0 driver now implements the Metal ExtEscape surface API, OpenGL/Metal presentation
notifications and remote child-window layer hosting. The original Wine 11 server-request compatibility
check and per-engine driver backup/restore remain in force. Wine 10 driver sources are unchanged.

Steam additionally selects DXMT only inside `steamwebhelper.exe` and defaults to GPU browser drawing
on the tested Wine 11.0 engine. Game renderer choices remain independent. The launcher supplies
cross-process capability before Windows environment creation; the native helper selects the browser
DLL search path before DLL loading. Explicit software/GPU choices persist; Wine 10 keeps its previous
software default. Fresh and refreshed generated Steam helpers receive the same policy. No Steam binary
patch is involved. Startup also aligns Steam's internal `GPUAccelWebViewsV3` preference with the
Nokcandu choice; an older saved off value otherwise kept the installed copy black despite the correct
launch environment. Both the integrated clean test and the installed Steam app rendered after this
synchronization. EA's Wine 11 page was also confirmed working, with resize/fullscreen verified after its shared driver
refresh and restart. Battle.net/Ubisoft Wine 11 pages still require separate verification; this fix does not
switch their selected engine versions.

See [the full investigation](investigations/wine11-launcher-surfaces-2026-10-30.md) for failed controls,
source/license attribution, the automated before/after probe, migration behavior and Undo.

Follow-up: remote browser layer hosts now participate in virtual-screen scale changes. Their exported
content uses fixed Windows-pixel bounds, while the owning Mac window updates host transforms during
live resize/fullscreen. This fixed Steam requiring minimize/restore to stretch and staying small in
fullscreen. The user confirmed both behaviors in installed Steam and EA. The correction is shared driver
presentation logic, not a Steam game profile.

## Graphics detection and existing installations (2026-11-01)

No recognized graphics API is an unknown result, not evidence of DirectX 8–9. Shared PE inspection now includes delay imports and bounded, agreeing sibling-game evidence for generic bootstrap launchers. New automatic selections use Compatibility when detection remains unknown. Existing settings are preserved: use **Check graphics requirements** in Graphics to review and apply a journaled correction; manual launchers retain hash protection and confirmed modes are not silently replaced. The installed Rocket League regression detects DirectX 11 behind `Launcher.exe`; gameplay is not verified. See [investigation, scope, migration and Undo](investigations/graphics-detection-2026-11-01.md).

## Battlefield 1942 LAN browsing investigation (2026-11-01, resolved on Windows host)

The user disabled the Windows host’s virtual Ethernet adapter and confirmed that the Mac now sees its Battlefield 1942 LAN game. This establishes virtual-adapter involvement, not the exact socket binding/routing mechanism. No shared Wine broadcast patch or Mac firewall change was required. Do not automatically disable adapters for other users or games; inspect physical/virtual interface bindings first. Undo is re-enabling the same host adapter (the discovery failure may return). See [evidence, scope and Undo](investigations/lan-discovery-2026-11-01.md). The reusable read-only query tool has two passing local UDP tests; post-change joining/gameplay and other games were not retested.

## BF1942 obsolete Internet master correction (2026-11-01)

Confirmed: the verified installed executable points to non-resolving `master.bf1942.sk`; the community master `master.bf1942.org` answers TCP 28900. The built-in BF1942 menu/mod-restart copy generator now replaces both verified padded hostname slots, preserving the original executable. Existing journal-owned copies migrate only with an unedited managed launcher and while the game is closed; explicit settings remain intact. Combined recipe Undo is available in Display. The old five-byte-only description below/above is historical: the current generated copy additionally changes six hostname bytes across two slots. Full suite: 203 tests, 6 skipped, zero failures. The user confirmed LAN browsing after disabling the Windows host’s virtual adapter. The first Internet correction failed because it changed only one of two hostname slots; after the two-slot revision, the user confirmed that Internet servers appear. Browser population is verified; public joining/gameplay has not been retested. See [hashes, evidence, migration and Undo](investigations/bf1942-internet-browser-2026-11-01.md).

BF1942 follow-up: the first installed Internet correction was incomplete because there are two identical old-hostname strings. Runtime tracing confirmed the browser still used the second. The revision updates both verified slots and asserts that no obsolete hostname remains, with a new full-file output hash and migration from the first attempt. The revised 203-test suite passed before installation; the user then confirmed that Internet servers appear in the installed game. Windows reportedly works with the same game folder, but its resolver/hosts settings and launch target were not compared. See the dated investigation for the failed first comparison; do not reinterpret this game-specific endpoint correction as a universal Wine networking patch.

Final verification (2026-11-01): user confirmed both LAN discovery (Windows virtual adapter disabled) and Internet server-list population (two-slot BF1942 master correction). Preserve the distinction between host-wide adapter configuration and a game-specific directory endpoint correction. Do not extend the BF1942 hostname patch to unrelated games; apply shared diagnostic and migration protections wherever relevant. Public-match joining/gameplay and other games were not retested.

## IPX networking component (2026-11-01)

The optional `ipx-networking` component installs checksum-pinned IPXWrapper 0.7.2 through the common protected installer for eligible private 32-bit games. It is not tied to ROM2’s name. Existing differing files/links are refused, native DLL rules are private to the game, and normal Undo preserves unrelated settings. ROM2’s engine returned Winsock 10047 without it; local IPX send/receive and legacy DirectPlay initialization passed with it. Basic TCP/IP passed with and without the wrapper. The user subsequently confirmed ROM2 hosting and cross-machine TCP/IP joining. Native-IPX discovery against the unchanged Windows 98 VM remains unresolved; see the native-IPX investigation below.

Saved/shared profiles include this trusted component ID automatically; the separate live service allowlist was also updated and checked against all 11 current fix IDs. New fixes must pass both app round-trip tests and service allowlist/normalization checks (`Tools/profile-check/`); do not silently lose a fix during sharing or publish DLL bytes/adapter identifiers in profiles. See [evidence, scope, installer protections, profile service change and Undo](investigations/ipx-rom2-networking-2026-11-01.md).


The IPX component includes Microsoft's checksum-pinned legacy DirectPlay core, TCP/IP provider and session helper to
avoid Wine 11's NULL extended-send callback during host creation with IPXWrapper.
Earlier installations offer **Update**, preserving their original Undo values;
profiles request the corrected component under the same `ipx-networking` ID.
Changed launchers, owned DLLs or networking rules are protected. Hosting probe
results and the pending cross-machine test are recorded in the
[ROM2/IPX investigation](investigations/ipx-rom2-networking-2026-11-01.md).


Game installation progress uses a separate window, allowing existing games and
Fixes to remain accessible during another game's setup. **Back to Library** keeps
the installation session; **Installation: game…** returns to it. Explicit Cancel
and Remove retain their existing protections. Existing saved installs resume normally.
See [nonblocking installation](investigations/nonblocking-installation-2026-11-01.md).


When installing to an external drive, recognized Inno Setup installers receive the
prepared game's Windows folder as their suggested destination, avoiding a second
copy when setup honors it. Other installers show the intended folder; choosing a
different location can still require relocation. Existing installations and active
copies are preserved. See [installer destination routing](investigations/installer-destination-2026-11-01.md).


ROM2's shared DirectPlay correction now has user confirmation for Mac hosting and
cross-machine TCP/IP joining with a Windows 98 VM. IPX discovery against that
native-IPX VM remains unresolved: UDP-wrapped and native Ethernet IPX need a
compatible peer transport or bridge. This is not a claim of native IPX interoperability.


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

## Recipe storage and settings overrides (2026-11-02)

Both shipped standalone recipes now expose user launch overrides and shared performance/microphone settings. Recipe defaults retain the tested launch method; alternate programs/renderers are user experiments and may need different dependencies. Zero Hour game files can move to ExFAT without moving its Wine prefix: preserve the existing relative `C:\Games\Zero Hour` link and replace its dedicated `SharedSupport/GameFiles` directory with the external-content link. Worms uses its declared C-drive game directory. Fresh installs and recognized closed existing launchers receive the same support; manual launcher edits are preserved. Profiles carry portable settings, not proprietary dependencies or OS permission grants. [Evidence, migration and Undo](investigations/recipe-storage-settings-2026-11-02.md).

### Microphone switch while playing

The shared Wine helper supports live microphone input changes without restarting games. Off stops active capture and guards new opens while preserving output; On resumes requested capture streams and permits new opens subject to macOS consent. Live-mode devices remain discoverable while Off because Wine caches its endpoint list, superseding earlier zero-device assertions. Some games need their own voice-chat settings refreshed after a failed open. Existing processes load the new helper on their next normal launch. Settings and profiles retain the microphone choice; OS consent stays local. The Mouse section also explains macOS's broad “Keystroke Receiving” wording for direct raw mouse input. [Evidence, scope, migration and Undo](investigations/live-microphone-switch-2026-11-02.md).

First-use caveat: macOS caches missing purpose metadata in a session started Off. Adding it mid-session did not prompt in the fresh-identity test; first authorization may require one close/reopen with On. The no-restart capture test used an already authorized identity.

### Shared-launcher microphone routing and helper Repair

Wine rewrites its argument list after startup. The microphone guard now preserves the initial program bytes so an enabled shared-client game does not fall back to its prefix's blocked default. This applies to all per-program microphone routes, including CS2; it does not enable Steam's separate microphone switch. Repair restores/verifies the owning host's audio/input helper and saved policies even for shared shortcuts, while preserving manual launchers and linked helper paths. Existing Windows processes must reopen to load the new code. Status polling and microphone setting work run off the UI actor to avoid beachballs. [Evidence and outstanding gameplay verification](investigations/shared-microphone-routing-ui-repair-2026-11-02.md).

Confirmed after installation: CS2 receives voice input and its microphone switch works mid-game. The shared fix covers all supported Wine game types; CS2 is the user-verified gameplay case.

### Wine server normal-close readiness

A shared server-only helper correction handles macOS reporting urgent/error readiness for a gracefully closed TCP socket. This can strand older GameSpy HTTP clients, including BF2, after login. Loopback regressions verify normal EOF becomes readable without becoming exceptional, while real urgent data and failed/reset connections remain visible. Applicable Wine environments receive the shared helper through normal generation, migration and Repair; their full Windows session must restart to activate it. Native Mac games and game-process poll calls are unchanged. No global hosts entry or BF2-only network suppression is used. After installation and a private-session restart, the user confirmed BF2Hub login succeeds and the multiplayer server list populates. The user also confirmed joining an Internet multiplayer match and running around. Basic gameplay is verified; extended sessions and every anti-cheat configuration remain untested. [Evidence, activation, profiles and Undo](investigations/wineserver-closed-socket-readiness-2026-11-02.md).


### Shared helper activation and Repair status

Nokcandu distinguishes installed helper updates from code loaded by a running Windows session, and shows when the full game/client session needs restarting. Failed status scans retain the last known running state and cannot authorize closed-game changes. Repair covers shared audio/input, screen helper, native app entry, generated wrappers and installed compatibility companions while preserving external edits and explicit settings. Missing optional companions require a checksum-verified recovery copy; otherwise Repair reports reinstallation is needed. Fresh generation and existing installation migration use the same paths. See [evidence, safe recovery, migration and Undo](investigations/helper-activation-repair-hardening-2026-11-02.md).

### Storage browsing in Settings

All libraries use the same on-demand Storage sections and virtualized lists. Recent estimates are cached only for the current Nokcandu session; Refresh remeasures. Folder-capacity queries and cleanup run in the background, while cleanup rechecks cached leftovers before Trash. This changes presentation and scan scheduling, not game compatibility settings, storage locations or APFS accounting. [Evidence, migration and Undo](investigations/storage-browser-performance-2026-11-03.md).

Storage accounting follow-up: Games now uses the shared location resolver for private, Steam, Battle.net, EA, Ubisoft and known native installations. Each game includes its separately stored content with drive/size details; shared launcher rows exclude content represented by their game rows. Missing content is explicitly incomplete. No game files are moved or modified. [Tests, bounded linked-folder discovery and Undo](investigations/storage-game-location-accounting-2026-11-03.md).

### Automatic installer-media drive ownership

Shared Wine initialization and engine updates record new disk-image mappings; background refresh removes eligible recorded mappings after unmounting and environment shutdown. Explicit Add Drive mappings, configured game discs, referenced letters and unknown historical mappings survive. Remove clears both DOS-device links without deleting their targets. Files & Tools exposes conflict-safe Undo. This applies to private and shared launcher environments, without an ET Legacy-specific rule or profile-exported machine paths. [Evidence, validation and limitations](investigations/automatic-installer-drives-2026-11-03.md).

### Automatic installed-store game entries

Steam, Battle.net, EA and Ubisoft completed local installations are checked in the background while Nokcandu is open; eligible games automatically get their normal managed shortcuts. Existing integrated store/native completion also refreshes the game list. Manual Add and discovery reuse the same product/host entry and preserve edits. Missing/offline/incomplete installations are skipped, deliberate removals stay removed, and manual Add/Trash restore can reintroduce them. This adds library entries without altering a running game's settings or host. Optional external Galaxy/Epic/Amazon client discovery is not implemented by this change. [Scope, tests, removal behavior and Undo](investigations/automatic-store-game-discovery-2026-11-03.md).

### Sikarugir Wine version selection

Game settings, new-install defaults and installation overrides share `WineSelection`. Wine 10.0 r8 remains the initial original tested default; available verified Sikarugir revisions from Wine 10.0 onward can be selected explicitly. Shared store games change their real host's engine together, Native IPX blocks incompatible targets, and every switch retains the existing trial/rollback protection. Fresh selected runtimes retain Repair provenance; recipe builtin-DLL verification follows the chosen engine. Defaults never retarget existing/resumed installs, and relevant cache entries are protected. [Evidence, validation, limitations and Undo](investigations/wine-version-selection-2026-11-03.md).

### Deferred setting changes without forced restarts

Ordinary settings now save independently of session shutdown. Wine/graphics/performance/display/program/recipe/hosted and compatibility changes apply safely while closed or remain visibly pending until the next full Windows start. Active programs are never terminated just to save a setting; idle services do not reopen a closed game. Shared hosts keep their existing scope, and live microphone/raw-mouse controls remain immediate. Generated app icons and Nokcandu Play share the persisted queue/helper, with fingerprint-safe migration and explicit failure/discard. [Evidence, limitations, cache retention and Undo](investigations/deferred-game-settings-2026-11-03.md).

## Nokcandu app-version recovery

Updates → Nokcandu can return to saved app copies or older stable GitHub releases with published checksums. Every managed replacement saves the current app first; games, saves, Wine selections and user settings remain in place. Existing installations gain recovery copies at their next replacement. Backups also contain an independent Restore Nokcandu.command for a broken UI or interrupted app swap. Older app releases may not understand newer settings, so recovery does not erase or downgrade user data. Undo by selecting the saved newer copy. See [implementation, evidence and limits](investigations/app-version-rollback-2026-11-03.md).

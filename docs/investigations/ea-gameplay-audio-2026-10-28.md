# Nokcandu troubleshooting record — EA games and related fixes

Date: October 28, 2026 (America/Chicago)
Machine: MacBook Air M4, Apple Silicon

Historical investigation snapshot. Settings and test counts below describe October 28, not current defaults. See [engineering learnings](../engineering-learnings.md) for the current conclusions. Local paths have been generalized for the repository; temporary evidence files are not included.

## Status at handoff

**Unresolved:** Battlefield: Bad Company 2 (BC2) and Dragon Age: Origins (DAO) have severe repeating/echoing gameplay audio. BC2 also has unreliable fullscreen positioning. No audio workaround tested in this session solved the problem.

**Working:** Populous opens without the recurring administrator prompt after the shared repair. The user previously confirmed BC2 and DAO reach visible gameplay, and that BC2's graphics are playable at low settings. DAO's missing-runtime startup failure was fixed.

**Delivered:** Shared EA installation/recovery improvements, per-game EA settings, correct external-installation size reporting, persistent elevation-flag repair, safer launcher restarts, last-played startup selection, native-helper loading, and engine/audio rollback safeguards. The final full suite ran 145 tests with 5 skipped and no failures. Those tests verify infrastructure; they do not establish that the audio or fullscreen issues are solved.

This record combines the conversation, retained project documentation, diagnostic results, and a final read of saved settings. Later audio comparisons were primarily conducted in **BC2**. Do not assume each comparison was also repeated in DAO.

## Symptoms to reproduce

- Both BC2 and DAO: the user reports short fragments of gameplay sounds repeating several times, with delayed effects such as gunshots. The result is severe enough to make the sound unplayable.
- Menus sound substantially better; the repetition is not readily noticeable there.
- The user says the games otherwise run reasonably well, and other games have not shown this same problem.
- BC2 fullscreen: the image can open oversized, be cut off at the top/right, or move upward with a black area below it. Command-Tab sometimes helps and sometimes makes it worse.
- Earlier BC2 borderless attempts had a constant mismatch between the visible pointer and the menu location it selected. Raw Mouse Capture on/off did not fix that mismatch.
- Populous: EA restored installer-added `RUNASADMIN` flags, bringing back its permission prompt and launch failure after an earlier manual repair.

## Final saved configuration snapshot

Read from disk when this report was prepared; later user changes can supersede it.

| Item | Saved state |
| --- | --- |
| EA client graphics | DXMT (`dxmt`) |
| EA client window style | Borderless enabled |
| BC2 per-game graphics | Older 3D / `dx9` |
| DAO per-game graphics | Older 3D / `dx9` |
| BC2 `settings.ini` | Width 1280, height 800, `Fullscreen=false`, `DxVersion=9` |
| BC2 sound settings | `Quality=high`, `SpeakerCount=0` |
| BC2 `GameSettings.ini` | `[GstAudio] SoundSystemSize=3` |
| EA audio buffer | Restored to Normal, 10 ms |
| Mac speakers | Original 44,100 Hz setting restored after the 48,000 Hz test |
| EA overlay | User turned it off; disabling it did not resolve the following audio test |
| Engine | EA stayed on Wine 10.0, Sikarugir revision 8 |
| Temporary environment overrides | No remaining virtual-device filter, older-renderer, synchronization, DSOAL logging, or Wine-debug overrides in the saved EA/BC2/DAO settings checked for this report |

BC2 remains windowed for continued diagnosis. This is a usable testing state, **not** a completed fullscreen fix.

## Audio trials and results

| # | Trial | What was verified | Result and disposition |
| --- | --- | --- | --- |
| 1 | Increase the Wine audio buffer to 20 ms and then 40 ms | User tested gameplay; 40 ms also adds substantial potential buffering delay | Repetition persisted. Restored 10 ms. Do not keep increasing the buffer as an established fix. |
| 2 | Repair native-helper loading in hosted game launchers | Initial live inspection showed BC2 was not loading `nokcandu-rawmouse.dylib`. After the shared fix, live mappings confirmed it loaded. Logs showed priority messages for `wine_dsound_mixer`, `audio_client_timer`, and other audio threads | A real shared launcher bug was fixed, but gameplay audio still repeated. Keep the infrastructure correction; do not describe it as the audio solution. |
| 3 | Capture Wine sound-driver warnings during gameplay | User entered gameplay, reproduced the repetition, and quit. Logs showed repeated `IDirectSoundBufferImpl_Lock Overwriting mixing position, case 1` warnings | Useful evidence, not proof of the root cause. There were two initial “Probable buffer underrun” warnings, but no continuing stream of underruns or GetBuffer/GetCurrentPadding failures. |
| 4 | Replace BC2's DirectSound implementation with official DSOAL r697 and its OpenAL Soft driver | Verified package checksum, used Win32 DLLs, and confirmed BC2 loaded the app-local `dsound.dll` and `dsoal-aldrv.dll` | User reported the same repetition. Both test DLLs and the test overrides were removed. Not shipped as a fix. |
| 5 | Restore the engine's original Mac audio driver for a comparison | Backed up Nokcandu's adjusted driver, fully restarted the test environment, and tested the original output-unit configuration | User still heard the repetition; an initial impression of improvement was not sustained. Nokcandu's normal driver was restored. |
| 6 | Disable extra Wine synchronization in the EA environment | Temporarily set `WINEMSYNC=0` and `WINEESYNC=0` for the client/game. Corrected helper launch ordering so it received the same settings | Still repeated. Restored normal synchronization. One launch did not immediately reach BC2; the actual game process was checked before treating the comparison as ready. |
| 7 | Force stereo with `SpeakerCount=2` and DirectX 9 | Confirmed the saved speaker value before the test | Still repeated. Stereo alone was not a solution. Original speaker setting restored. |
| 8 | Check output devices and EA overlay/XAudio usage | Mac default output and system output were MacBook Air Speakers; default input was the built-in microphone. BC2's mapped modules showed DirectSound, no XAudio, and no detected EA overlay module in that inspected process | Did not establish an XAudio problem. Blanket `xaudio2_7`, `xaudio2_8`, or `xaudio2_9` overrides were **not** applied. |
| 9 | Change the physical speakers from 44.1 kHz to 48 kHz; restart EA and BC2 with overlay off | Audio MIDI Setup showed 44,100 Hz initially, 48,000 Hz for the comparison, then restoration to 44,100 Hz. The user had disabled EA's overlay | Still repeated. Original 44.1 kHz restored. A 96 kHz default was not the observed condition on this Mac. |
| 10 | Combine stereo, medium sound quality, DirectX 9, and sound-system profile value 2 | Changed the actual `GameSettings.ini`, under `[GstAudio]`, plus `settings.ini`. Saved backups first | Still repeated. Restored original quality/profile/speaker values. Do not promote the combination to a recommendation. |
| 11 | Compare with the older bundled DirectX 9 renderer | Live mappings confirmed the older renderer. Its runtime log actually reported `DXVK-Sikarugir: v1.10.3-async` | Audio still repeated and graphics struggled more. Restored the working renderer. The app's description was corrected to avoid incorrectly calling this bundled renderer “DXVK 2.3.” |
| 12 | Check a newer Wine 11.0 revision 1 engine separately | Official package checksum and `--version` passed. A separate scratch prefix failed `cmd /c ver` with exit 1. Nokcandu already had a prior failed-test record for this runtime | EA was **not upgraded**. Existing Wine 10 engine and game installations remained in place. |
| 13 | Hide virtual audio endpoints from BC2 only | Built a temporary native helper outside the repository. Log confirmed it hid two virtual devices and retained three physical devices. Mac audio devices and Jump Desktop were not disabled | Still repeated. Restored the normal helper and removed `NOKCANDU_AUDIO_HIDE_VIRTUAL`. Experiment not shipped. |

### Important limits on these conclusions

- None of the above established the root cause of the gameplay audio repetition.
- A loaded helper, a successful installer, a running process, and passing automated tests are separate from successful audible gameplay.
- The sound-driver warnings are correlated observations; they were not proven to cause the repeats.
- The supplied screen recording, `Screen Recording 2026-10-28 at 9.04.58 PM.mov`, contained a video stream but **no audio track**. Its approximately 24.7 seconds of video helped with display observations, but could not be used to hear or measure the repetition.
- The engine self-test failure was reproduced separately. No failed-test marker was cleared merely to force an engine change.

## BC2 display and mouse trials

1. **Windowed DirectX 9:** made the game playable/visible, but the user wanted fullscreen or borderless presentation.
2. **Generic borderless resizing:** filled the screen, but menu clicks were offset by roughly a constant amount. The pointer appeared above and left of the location the game selected.
3. **Raw Mouse Capture on and off:** did not correct the menu offset.
4. **Command-Tab:** did not fix the earlier constant click offset.
5. **DPI-awareness experiment in the Windows borderless helper:** did not fix the offset. Source/helper experiment was reverted.
6. **BC2's own fullscreen at the logical desktop size, with DirectX 9:** the user initially confirmed aligned clicks and working Command-Tab. A desktop-size recipe was implemented and shared.
7. **Subsequent launches:** exposed oversized/cropped/shifted presentation again. This invalidated any claim that the fullscreen recipe was consistently solved.
8. **Smaller window for audio tests:** allowed Singleplayer to remain accessible without relying on fullscreen recovery. The final saved size read for this report was 1280 × 800, windowed.

Additional observations: one inspection, after the user had centered the image, showed an onscreen game window at `(0,0)` with bounds 1280 × 800, on a display with logical size 1280 × 800 and physical size 2560 × 1600. Renderer logs also contained repeated swapchain recreation/suboptimal messages and periods with a very small reported surface. These observations need correlation with a reproducible bad launch; they are not a confirmed explanation.

## Successful fixes retained in Nokcandu

### Populous: repeated administrator prompt

**Cause confirmed:** EA had restored `RUNASADMIN` on three programs in Populous's DOSBox directory: `DOSBox Launcher.exe`, `DOSBox.exe`, and `Populous.exe`.

**Retained shared repair:**

- A bundled Windows helper queries registered Electronic Arts game installation roots.
- It removes only standalone `RUNASADMIN` tokens from existing programs below those roots.
- Other compatibility tokens, unrelated programs, and game binaries remain unchanged.
- It saves original values before modifying them, under `HKCU\Software\Nokcandu\CompatibilityBackups`, with subkeys identifying the original hive/view.
- It runs at EA startup, hosted-game startup, and after successful manual setup recovery.
- A prefix-local watcher checks for flags restored by install/repair while EA is open, and exits after EA closes.

**Verification:** the user confirmed Populous appears without the permission prompt. A simulated restored flag was removed again automatically. A separate temporary registry test retained `WIN7RTM` and `HIGHDPIAWARE`, while an unrelated program kept its elevation flag.

### Fully applying settings in shared launchers

- Settings that require restart now use one confirmation/apply/reopen flow across applicable private and shared Wine environments.
- The prompt explains that games and Windows programs in that environment will close and unsaved progress can be lost.
- Raw mouse settings that apply live stay on their live path.
- A real failure was observed where a native Wine game survived after its Windows server exited.
- Shutdown now checks actual native executable paths in the selected app's private engine/GameApp locations, closes survivors, waits, and then applies settings.
- It does not use a global kill of every Wine process on the Mac.
- Tests cover a real orphaned fixture process and an unrelated process that must survive.
- The restart prompt was checked in the installed UI; canceling it returned to the unchanged saved setting.

### Per-game settings, storage, and selection

- EA game shortcuts keep their own graphics, launch options, safe environment overrides, performance settings, and raw mouse flags.
- Raw mouse is not implicitly inherited as enabled from the EA host; a missing per-game flag means off.
- Native-helper injection is scoped to Wine commands, keeping the Intel helper out of native ARM64 utilities.
- Generated launcher updates are fingerprinted; manually edited launchers are preserved.
- DAO storage reporting now uses the store-registered installation root instead of only `bin_ship`. The display changed from about 198 MB to about 63 GB. No content was moved or deleted for this correction.
- Startup selection uses actual Play history when available, rather than letting a health-check log timestamp select an older game.

### Safe engine changes and rollback

- Hosted shortcuts are excluded from the list of apps that own engines.
- Engine replacement uses the shared shutdown checks.
- The saved original audio driver is reset for a new engine, retained in the old engine's rollback record, and restored with that old engine.
- This prevents a later audio-buffer adjustment from writing an older engine's driver into a newer engine.
- Tests cover both present and absent audio baselines.

## Earlier EA installation and game-start repairs

These are retained project findings from the preceding work, rather than new audio solutions.

| Problem | Retained approach / outcome |
| --- | --- |
| EA bootstrapper `INST-14-1627` | Install the official, verified complete MSI using its supported `EAX_DISABLE_SYMLINKS=1` property and the bootstrapper's required package metadata/cache registration. No patched installer or certificate bypass. |
| EA waited/blank browser | Select valid, matching-architecture Microsoft C++ libraries already shipped with the app; keep DXMT and cross-process window support. Software browser/Qt flags and alternate renderers alone were insufficient. |
| EA pages only visible in borderless | User confirmed borderless made the pages visible and sign-in worked. Kept that working setup. Ordinary window rendering remains fragile. |
| Missing EA button icons | A shader probe reproduced a Wine compiler error; Microsoft's `d3dcompiler_47` compiled the same shader. The shared compiler component fixed visually checked icons. |
| EA local/background/elevation helper problems | Exclude services, browser workers, EA elevation/background/local-host programs from foreground game window/input/display hooks. Avoid duplicate EA test environments competing for localhost port 3216. |
| BC2 final installation failure | Invoke the downloaded game's original `__Installer/Touchup.exe` with the supplied manifest command through “Finish EA Game Setup.” No trust-store or signature-verification bypass. User confirmed BC2 starts. |
| DAO missing `NxCharacter.dll` message | The file was present, but its PhysX dependency was missing. Installing NVIDIA's official PhysX runtime let the user reach the visible game. |
| DAO DLC finalization failures | Discover original contained DLC setup packages, accept their `pdlcinstall` commands, and pass the base installation root correctly. Ten add-on setup packages completed in the recorded test. This does not fake EA's download-manager state. |
| Installer output/cancellation hangs | Shared bounded, nonblocking output collection no longer waits for EOF held by descendants after the original process exits. |

## Earlier related game-specific work

Included for continuity; the detailed retained implementation is in the repository documentation.

- **BF1942:** shared DirectX 8/9 compatibility and Microsoft shader components; game-specific allowlisted video configuration edits; verified copies for menu-size and mod-restart correction; borderless presentation. The user confirmed mod activation and a match subsequently loaded after the missing shader libraries were installed. These are separate from the unresolved BC2/DAO audio issue.
- **BF1942 mod/video errors:** an observed profile had 2560 × 1600 in 16-bit color while the receipt still recorded 1280 × 800. The repair used the selected 32-bit gameplay mode and preserved the corrected executable across mod restart. A later shader-creation failure required the shared shader component, not another restart-name patch.
- **OpenUA invisible window:** `gfx.vbo = off` in `NUCLEUS.INI` made the intro/menu visible. Windowed-only experimentation did not solve the original rendering failure.
- **OpenUA tiny menu:** provide supported custom modes, preserve its 640 × 480 menu mode, and use `menu.windowed = off`. The built-in recipe is restricted to the matching OpenUA installation and supports saved/shared profiles.
- **Generals Zero Hour native Python failure:** scope the x86_64 helper to Wine rather than globally exporting it into ARM64 Python. This was fixed in shared launcher generation rather than by changing Zero Hour's renderer or requiring an Intel Python.

This appendix is not a claim that every earlier game or installer has received a new complete playthrough.

## Files and implementation references

Repository: this checkout

- `Sources/NokcanduCore/EACompatibility.swift`
- `Resources/borderless/ea-compat.c`
- `Resources/borderless/compat-flags.h`
- `Sources/NokcanduCore/HostedSettings.swift`
- `Sources/NokcanduCore/WineTools.swift`
- `Sources/Nokcandu/AppModel.swift`
- `Sources/NokcanduCore/AudioBuffer.swift`
- `Sources/NokcanduCore/Updates.swift`
- `Sources/NokcanduCore/EASetupRecovery.swift`
- `Sources/NokcanduCore/BC2DisplaySettings.swift`
- `docs/compatibility-fixes.md`

Installation layout recorded during the investigation (portable examples):

- EA host: `~/Applications/Sikarugir/EA app.app`
- BC2 shortcut: `~/Applications/Sikarugir/Battlefield Bad Company x2122 2.app`
- DAO shortcut: `~/Applications/Sikarugir/Dragon Age Origins.app`
- Game installations: `<game-library>/EA Games/`
- BC2 configuration: `~/Documents/BFBC2/settings.ini` and `GameSettings.ini`
- DAO configuration folder: `~/Documents/BioWare/Dragon Age/`

The `x2122` in BC2's old app filename is a legacy name-decoding artifact. Do not rename paths blindly when reusing diagnostics.

## Published checkpoints

- [41df138 — per-game EA settings and shared setup recovery](https://github.com/seastwood/Nokcandu/commit/41df138)
- [a2aa6ff — persistent EA repair and shared launcher restart](https://github.com/seastwood/Nokcandu/commit/a2aa6ff)
- [7156afb — engine/audio baseline and rollback safeguards](https://github.com/seastwood/Nokcandu/commit/7156afb)
- [4e2de8f — completed audio comparisons and restored test state](https://github.com/seastwood/Nokcandu/commit/4e2de8f)

The code fixes were installed in `~/Applications/Nokcandu.app`. No release/tag was created. 

## Temporary evidence and recovery files

These paths existed during troubleshooting under `/private/tmp`. They are **not permanent backups** and can disappear after cleanup/restart. The findings above remain useful without them. Do not restore a driver/helper merely because a temporary filename exists; verify its engine version and current file ownership first.

### Useful logs

- `/private/tmp/nok-audio-trace-start.log`
- `/private/tmp/nok-dsoal-test-start.log`
- `/private/tmp/nok-original-audio-test-start.log`
- `/private/tmp/nok-sync-test-start.log`
- `/private/tmp/nok-stereo-test-start.log`
- `/private/tmp/nok-48khz-test-start.log`
- `/private/tmp/nok-sound-profile-test-start.log`
- `/private/tmp/nok-old-renderer-test-start.log`
- `/private/tmp/nok-virtual-audio-start.log`
- `/private/tmp/nok-wine11-isolated.log`
- `/private/tmp/nok-final-audio-cleanup.log`
- `/private/tmp/nok-engine-protection-final-tests.log`

The sound warnings themselves were captured in BC2's own `Contents/SharedSupport/Logs/launch.log`, which later launches can overwrite. EA logs may contain account/session information; do not publish them wholesale.

### Temporary snapshots used

- `/private/tmp/nok-bc2-settings-before-audio-trace.json`
- `/private/tmp/nok-ea-host-before-sync-test.json`
- `/private/tmp/nok-bc2-display-before-audio-test.ini`
- `/private/tmp/nok-bc2-before-sound-profile-GameSettings.ini`
- `/private/tmp/nok-ea-audio-before-original-driver.so`
- `/private/tmp/nok-ea-helper-before-virtual-audio-test.dylib`

### Verified DSOAL test package

Official source: `kcat/dsoal`, prerelease `latest-master`, DSOAL r697.

- Downloaded ZIP SHA-256: `1d70fc40efcb877bee65ce2a40ceb07fe35c16d51629bd7c4782caf37a4a864f`
- Win32 `dsound.dll` SHA-256: `c304c7c822e885d35d016ef2667ed98bd3c3f688d16c35ce5e412d61749542cf`
- Win32 `dsoal-aldrv.dll` SHA-256: `5944247737a79b21f6225b5af962154c66903e0800b6287525de137113c3d52d`

The rolling prerelease URL can change. These hashes identify the tested files, not every future download. Both app-local test DLLs were removed after the failed comparison.

## Recommended starting point if work resumes

1. Read this report and inspect the current settings again; do not assume the user has made no changes since October 28.
2. Obtain a short recording containing actual audio: a few individual gunshots and the resulting repeats. A phone recording of the speakers is sufficient. The earlier silent MOV cannot answer this.
3. Keep the working renderer and normal synchronization. Confirm the game actually opens before asking for a sound test.
4. Measure repeat spacing and decay from the audio. Use that to distinguish a replayed buffer, timing/streaming failure, or an effect/echo path before introducing another component.
5. Diagnose DAO separately enough to establish whether it shares the same audible failure as BC2. Most later comparisons above were BC2-only.
6. Reproduce the fullscreen failure separately, including a cold launch and Command-Tab out/back. A one-time centered image does not prove a persistent fix.
7. Preserve saves, user settings, manually edited launchers, and the EA client's working DXMT/borderless setup.
8. Keep fixes in shared generation/migration paths when the fault is shared. Restrict genuine game settings to the identified game. Do not make failed audio experiments defaults or advertised fixes.

## Explicitly not established or not completed

- No successful fix for the BC2/DAO repeating gameplay audio.
- No reliable final solution for BC2 fullscreen positioning across repeated launches.
- No XAudio override test, because inspected BC2 used DirectSound and did not load XAudio.
- No successful Wine 11 upgrade of EA.
- No test moving the complete BC2/DAO installation onto the internal SSD; external-drive streaming remained an unproven possibility, not a diagnosed cause.
- No change to macOS audio drivers, certificate trust stores, or system security protections as an audio workaround.
- No guarantee that every EA game, DRM scheme, DLC installer, or launcher will work out of the box.

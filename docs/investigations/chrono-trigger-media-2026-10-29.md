# Chrono Trigger media startup — October 29, 2026

## Symptom and evidence

On the tested M4 MacBook Air, the Windows Steam edition of Chrono Trigger (Steam app 613830, build 11890051) displayed the Square Enix logo and then a black screen. Its 32-bit Cocos2d library imports Media Foundation. LAV Filters 0.83 was already present; adding DirectShow codecs was not an established remedy for this Media Foundation failure.

The game extracted an H.264 1920 × 1080/AAC MP4 into its Windows temporary folder. Targeted Wine traces showed `wg_parser_create` failing before decoder selection. Media Foundation reported `0x8007000e` and later `0xc00d36bb`. Wine 10's [media_source.c](https://github.com/wine-mirror/wine/blob/wine-10.0/dlls/winegstreamer/media_source.c) maps parser creation failure to E_OUTOFMEMORY; this message alone does not establish physical RAM exhaustion.

The bundled Unix media module refers to GStreamer libraries through `@rpath`. The generated runtime environment included the app's `Contents/Frameworks` but omitted `Contents/Frameworks/GStreamer.framework/Versions/1.0/lib`, where those libraries actually reside.

## Controlled comparison

A diagnostic launch in the existing signed-in Steam environment added that bundled library directory to `DYLD_FALLBACK_LIBRARY_PATH`, retaining the app Frameworks directory and `/usr/lib`. No codecs were downloaded and no movie, game executable or game configuration was patched. The trace then created an IMFMediaSource and completed source resolution with status zero. The user confirmed that the game worked.

This comparison establishes the media-loading correction for the observed startup failure. It does not establish a remedy for the separate BC2/DAO gameplay audio problem. Diagnostic logging was stopped; the large temporary trace was reduced to bounded excerpts. Raw account/session logs and game assets are not stored here.

## Shared implementation

`WineEnvironment` supplies the same bundled media library path to generated standalone and shared-launcher scripts, installers, Wine tools and component installation. Fresh generated apps receive it automatically. Existing recognized generated scripts migrate through their normal refresh paths; recipe fingerprints normalize only this managed addition, and manually edited launchers remain protected. Steam's running-configuration fingerprint includes the library path, so a host started with the previous environment is recognized as requiring a restart.

Separately, Apply and Restart previously reopened only the host. It now reopens the selected game's standard launcher after the settings change succeeds. That launcher starts its host and requests the game in one action. If the settings edit fails, recovery reopens only the host and reports the failure.

These are shared integration corrections, not Chrono-only compatibility components or OS-wide environment changes. No game-file Undo is required because this fix modifies generated runtime integration only; existing settings journals continue to retain their own changes.

## Verification and limits

The full automated suite completed 182 tests, six optional skips and no failures. Tests execute generated shell exports, compare native/tool/installer paths, verify recipe normalization and preservation of unrelated text, verify Steam fingerprints change with the media path, and assert selected-game relaunch on success with host-only recovery on error. The signed release build completed.

The controlled diagnostic launch is user-confirmed. The signed update was installed and its signature verified. An explicit local integration check invoked the actual settings-restart API with the selected Chrono Trigger app, retained its saved settings, and passed: the standard shortcut requests app 613830 and the refreshed Steam helper contains the media path. The temporary local harness was removed. A direct window-inspection attempt stalled and did not produce a screenshot, so visible rendering after this normal relaunch is not independently verified. Passing API/unit checks is not a gameplay result.


## Follow-up: normal launch black screen and engine detection

The normal Steam launch still went black after the Square Enix logo. Its log progressed beyond the earlier parser creation failure but reported DXVK-Sikarugir 3.1.1 failing to create a Vulkan presentation surface (`VK_ERROR_INCOMPATIBLE_DRIVER`). The original direct diagnostic had not selected that renderer. The earlier successful direct run therefore did not establish that the saved Older 3D games mode would work. Both errors must be distinguished.

Changing the selected game's saved graphics mode to Compatibility through the standard settings/restart API, then starting it through its normal Steam shortcut, resolved the black screen. The user confirmed the game was working. Its saved configuration, generated shortcut and running Steam mode all read `wined3d`; an already-open Nokcandu view briefly displayed its stale earlier selection. No movie skip, asset edit or codec installation was used. The GStreamer fixed-caps warning still occurred in the working run, so that warning alone is not a reliable failure detector.

The executable imports `libcocos2d.dll`; that local engine DLL imports `OPENGL32.dll`. The previous default detector examined only the executable and missed this dependency, falling back to Older 3D games. The shared detector now follows actual imported DLLs in the executable's real directory, with architecture, path, dependency-count and byte limits, cycle protection and case-insensitive Windows-name matching. Direct graphics evidence in the executable retains priority; unrelated adjacent DLLs do not select a mode. No Windows/PATH search, executable execution or game-file modification is involved.

Fresh Steam/general installations and hosted-game defaults use this detector. Recommended Settings uses the same reached graphics evidence and can propose Compatibility for OpenGL-only games, while preserving a graphics mode marked as working. Existing saved settings are not broadly overwritten; this game's saved mode was explicitly corrected. Other OpenGL games can benefit from the detection rule, but Compatibility is not forced on DirectX games or globally selected for all Media Foundation playback.


Follow-up verification: 184 automated tests completed with six optional skips and no failures. A separate explicit local check on the installed game files confirmed both the default detector and Recommended Settings choose Compatibility; the temporary harness was removed. The signed release build passed. The working normal launch is user-confirmed; the saved configuration, generated shortcut and running host all use Compatibility.

The signed update was installed and its signature verified. Direct inspection of Nokcandu after reopening showed Graphics: Compatibility, matching the saved configuration and active host. The game remained running during this app-only update.

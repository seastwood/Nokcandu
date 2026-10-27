# Next improvements for Nokcandu

Reviewed 27 October 2026. These are proposals, not changes made to installed game runtimes.

Nokcandu already has isolated game apps, profiles, optional fixes, crash hints, preflight/repair tools, and runtime update trials. The next work should strengthen those features rather than replace working setups with a newer graphics stack by default.

## 1. Report the renderer actually used

Show “Configured” and “Loaded” separately, including the Wine engine, translation library version, and whether a fallback occurred. BF1942 demonstrated why this matters: the selected preset could look suitable while a different path produced rendering or performance problems. A concise compatibility explanation is more useful than another unexplained backend toggle.

MetalSharp documents selection from game imports and tested routing rules. The useful design lesson is to combine detection with title-specific evidence, rather than treating a backend's nominal DirectX support as proof that a particular game works. [MetalSharp source and routing overview](https://github.com/metalsharp/MetalSharp).

## 2. Make experiments safe and easy

Extend runtime trials into a “Try in a test copy” workflow covering configuration, registry, components, and saves. Clearly name the working baseline and the trial, and track their roles explicitly rather than inferring them from filenames. APFS cloning can reduce the initial cost, but the UI must explain logical size versus uniquely allocated storage. Never overwrite the working baseline because a menu opened successfully.

CrossOver exposes bottle duplication and archive/restore, and recommends archives before configuration changes. These are useful workflow ideas to adapt to Nokcandu's own per-game model. [CrossOver bottle commands](https://support.codeweavers.com/en_US/crossover-mac-user-guide#bottle-commands-via-main-menu).

## 3. Turn compatibility reports into useful evidence

Keep separate results for startup, menu, match loading, gameplay, audio, mouse, controller, and app switching. Record game edition/fingerprint, Mac model, engine, renderer, resolution, and test date. Distinguish “worked on this M4 Air” from a universal recommendation. Rank profiles using comparable hardware and runtime evidence, while allowing manual choice and Undo.

## 4. Add a repeatable performance comparison

Use a user-selected in-game scene or a supported game's built-in benchmark. Compare frame times, sustained performance, memory pressure, and audio stability across candidates; menu FPS alone is insufficient. Balanced, Battery, and Quality presets should be evidence-based and should not rewrite the game's settings while it is running. This is particularly valuable on a fanless MacBook Air.

MetalSharp describes multiple graphics routes, including an older-game D3D9 path and controller options. Those are candidates for isolated testing, not drop-in guarantees for Nokcandu. [MetalSharp documentation](https://www.metalsharpmac.com/docs).

## 5. Expand fixes without affecting other games

Add per-program component routing for Steam and other shared launchers, so a shader or input fix need not change every game in the shared environment. Keep component versions pinned, preview conflicts, and preserve independent Undo. Add explicit Windowed and Fullscreen controls only where a game-specific adapter can actually set them; keep Fullscreen (Borderless) as the tested BF1942 recommendation.

## 6. Strengthen storage and recovery

The current update adds drive-aware sizing and verifies the ExFAT files-only path. Next, add an integrity report before deleting a source copy, resumable large transfers, clearer disconnected-drive states, and explicit handling of older global reset histories. Distinguish app/runtime, game files, known saves/settings, and shared launcher space. Do not promise that an allocation estimate equals space reclaimed after deletion.

## Engineering policy

Study workflows and public designs first. Any code or runtime reuse needs its own license and dependency review; MetalSharp identifies its project as AGPL-3.0-or-later, and its components retain their separate licenses. This investigation did not install either product, copy its code, replace the Wine runtime, or change a working game's graphics route. [MetalSharp license and component notices](https://github.com/metalsharp/MetalSharp#license).

Recommended order: actual-renderer reporting, safe test copies, better compatibility evidence, then benchmark-guided defaults and broader renderer/input support.

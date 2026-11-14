# Launcher notes: optional fixes, display controls, profiles and storage

Moved from the README on November 13, 2026, unchanged.

## Optional compatibility fixes

A standalone game's **Fixes** panel offers three opt-in components alongside LAV Filters:

- **DirectX 9 extras** downloads Microsoft's June 2010 redistributable and extracts only `d3dx9_43.dll` and `d3dcompiler_43.dll` beside the selected executable, matching its architecture. Nokcandu does not redistribute Microsoft's DLLs.
- **DirectX 8 compatibility** downloads crosire's d3d8to9 1.16.0 (BSD-2-Clause) and selects the Sikarugir runtime's older DXVK renderer. It requires a 32-bit game, **Older 3D games**, and the bundled `renderer/dxvk/wine` build. The default renderer remains unchanged for other games.
- **Fullscreen (Borderless)** uses Nokcandu's source-built Windows helper, available for 32- and 64-bit games. Choose Windowed in the game. The helper sizes visible, unowned game windows to their monitor without changing the Mac's display mode or keeping the game above other apps. It preserves launch arguments and follows restarts of the same executable; unrelated child launchers aren't followed.

These components currently require a game's own managed Windows environment and a program on its private C: drive. Shared Steam/Battle.net/other launcher environments are excluded until per-program routing is available. The generic components don't edit game executables. BF1942 also has a built-in Display recipe: **Apply Recommended BF1942 Display Settings** creates a fingerprint-checked menu copy, sets 1280 × 800 windowed gameplay, keeps the Mac at its desktop resolution, and enables borderless display. Its original executable is preserved. Other BF1942 executable variants need verification before menu-copy support can be enabled.

Each fix records its files and settings. **Undo** restores replaced files and its own DLL rules while preserving other fixes, and refuses to overwrite later manual edits. Quit the game before installing or undoing a fix. Undo installed components before changing the selected executable; undo DirectX 8 compatibility before changing its graphics mode. Profile settings Undo leaves installed components in place: use each component's Undo in Fixes to remove it.

Profiles reference only built-in IDs: `cinematic`, `d3d8to9`, `directx9-extras`, `borderless`. Applying a profile previews downloads and unavailable fixes. Profiles cannot supply binaries, download URLs, scripts, config commands, or patch bytes. Schema 2 can reference Nokcandu’s built-in BF1942 display recipe and a supported gameplay resolution.

Builds compile the Windows helpers with pinned Zig 0.15.2 from [ziglang.org](https://ziglang.org/download/), and the standalone archive tool with [cabextract 1.11](https://www.cabextract.org.uk/) (GPL-3.0-or-later). The app includes cabextract's license, corresponding source archive, and build recipe. Build scripts verify SHA-256 before extraction; `ZIG` may point to an existing official 0.15.2 toolchain.


## Display controls

**Mac screen resolution** changes the Mac's display temporarily. **Window style** selects Game default or the same optional Fullscreen (Borderless) component available in Fixes. **Game resolution**, currently available for standalone BF1942, edits the game's own video profiles and offers 800 × 600 through 1920 × 1200 independently of the Mac's supported screen modes.

BF1942's recommended display button handles the menu-resolution correction separately from gameplay resolution. It accepts only two verified full-file fingerprints, writes a separate `BF1942-Nokcandu.exe`, sets windowed mode, and retains an Undo receipt. Launches verify both the source and corrected copy so a game update cannot silently use a stale copy. Undo restores original video files and removes a borderless component only when the recipe installed it. Components installed separately are retained. Later manual edits are preserved and reported. Graphics translation and shader extras remain separate optional fixes.

The recipe is built into Nokcandu. Schema 2 profiles store its name, supported gameplay resolution, and whether the menu correction is required; Nokcandu still verifies the target executable and applies only its own built-in operations. Profiles never contain executable patches, config commands, or arbitrary paths.


## Complete profiles and storage (0.9.9)

Private-game profiles use schema 2; shared-launcher profiles use schema 3 so older builds safely skip the new per-game routing behavior. Profiles include experimental once-per-frame mouse delivery and supported BF1942 display settings. Schema 1 profiles still load and preserve the current once-per-frame setting when that field is absent. Older app builds skip schema 2 rather than silently ignoring its new settings. Profile previews identify unsupported game recipes; applying a BF1942 profile to another game never runs its display recipe. Profile Undo restores display files and their prior Undo ledger, while preserving later user edits. Installed component fixes still have their own Undo in Fixes.

The game header shows estimated storage and its drive, with a breakdown for separately stored game files and known settings/saves. A refresh button recalculates it. Native apps added manually are labelled “App” because arbitrary external game data cannot be inferred. Shared Steam/Battle.net runtime space belongs to the shared launcher. APFS allocations are estimates because cloned files may share blocks.

Move tests cover whole apps, renderer-path rebasing, portable per-fix Undo, file-only moves, and return to internal storage. A disposable BF1942 setup was also moved to a connected ExFAT drive and back with byte verification and working Undo. ExFAT is explicitly kept on the files-only path even when macOS reports symlink support; free-space checks fall back to filesystem capacity when the important-usage estimate incorrectly returns zero. Existing games are not relocated automatically.

# Overwatch 2 and ARM64 Wine readiness (2026-11-05)

## Overwatch 2

Overwatch 2 runs through Battle.net with DXMT (DirectX 11 → Metal). Its known failure on macOS Wine is memory growth from DXMT keeping compiled shader IR; long matches end in an out-of-memory crash. NerRobDog's DXMT `v0.80-ow2-0.2` pack releases shader IR after compiling (`d3d11.releaseShaderIR`, on by default in that build).

- Verified on this Mac: the pack's DXMT libraries load in Nokcandu's Wine 11 engine and render a D3D11 test program.
- Not verified: Overwatch itself (not installed on this Mac).
- Implemented as the shared component `dxmt-low-memory` (any DXMT program, not an Overwatch hack): the pack is downloaded once per program, SHA-256 pinned, only `.dll`/`.so` files from known architecture folders are kept (no symlinks), and `WINEDLLPATH_DXMT` points that program at them. Undo removes the folder and the setting.
- Battle.net's Overwatch page (`Pro`) gets an Overwatch Setup section that applies DXMT and the component.

Anti-cheat: Overwatch 2 already plays under Wine/Proton, so no extra layer is needed; games whose anti-cheat refuses Wine (kernel drivers, or EAC/BattlEye without Wine support enabled by the developer) remain out of reach.

## ARM64 Wine

Upstream Wine builds natively for macOS ARM64; Intel Windows programs need an emulator inside Wine: FEX's `libarm64ecfex.dll` (64-bit, ARM64EC) and `libwow64fex.dll` (32-bit, WoW64). Graphics translators (DXMT, D3DMetal, DXVK/MoltenVK) must also be ARM builds. Rosetta is mostly going away with macOS 28.

Changes so Nokcandu can take an ARM engine as soon as one ships:

- `EngineLayout` detects the engine's processor from `lib/wine/aarch64-unix` vs `x86_64-unix` (falling back to the loader's Mach-O) and is the only place that knows the folder names. Used by GameApp (loader + ntdll links), WineTools ownership, AudioBuffer, NativeIPXNetworking, WindowedPresentation and the raw mouse library.
- `runs32BitX86` / `runs64BitX86` check for the FEX (or Windows' `xtajit`) modules.
- `EngineVersion.arch`: `…_arm64`/`…-aarch64` assets; tags round-trip; old saved versions decode as Intel; `latestEngine` never picks ARM; `armEngines` lists them.
- `WineSelection.incompatibility` blocks an ARM engine for environments whose programs it can't run, using the downloaded engine's layout.
- RuntimeManager refuses an ARM engine whose arch doesn't match its asset name, or one combined with an Intel-only template.

Still needed when an ARM engine exists: an ARM Sikarugir template (wrapper, MoltenVK, DXMT/D3DMetal ARM builds), an ARM build of the winemac window driver used by the resizable window, an ARM build of Nokcandu's native IPX module, and a real end-to-end test. Rosetta stays required in Setup while the tested default engine is Intel.

## Follow-up (2026-11-06)

- Overwatch's Battle.net uninstall entry uses uid `prometheus`; its launch code is `Pro`. The fallback (uid in capitals) made Battle.net open without starting the game and hid Overwatch Setup. Fixed with real codes for `prometheus`, `heroes`, `diablo3`; stale links and generated launchers are repaired on load. Verified: Overwatch.exe starts from its Nokcandu entry within 10 s and stays up.
- MemoryWatch samples the game's own program (`proc_pid_rusage` physical footprint) during the normal status pass. Overwatch at the main menu, default graphics: 3.1 GB peak. A session counts as heavy at ≥45% of RAM and ≥4 GB.
- Open: a crash capture in the shared Battle.net prefix (03:43) contained only winedbg's usage text after attaching, i.e. the event-handle argument wasn't accepted. Not reproduced; the report parser ignores it.

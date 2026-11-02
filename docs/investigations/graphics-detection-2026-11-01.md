# Graphics detection: bootstrap launchers and unknown APIs (2026-11-01)

## Confirmed cause and scope

The reported Rocket League installation selected `Binaries/Win64/Launcher.exe`. That program provided no recognized graphics API to the previous detector. `GraphicsPreset.suggest` treated both an unreadable executable and an empty graphics result as DirectX 8–9. This is a shared inference defect, not a Rocket League recipe issue. A 64-bit executable alone does not prove a DirectX version, and release age does not determine the renderer.

The installed folder also contains `RocketLeague.exe` and `RocketLeague_EAC.exe`. A read-only regression against these installed files verifies that the bootstrap-aware detector finds `d3d11.dll` and suggests Modern 3D. No game bytes or account logs are stored here. The saved Rocket League setting was already Apple Metal at inspection; it was not overwritten.

## Shared correction

- Parse RVA-based PE delay-import descriptors as well as ordinary imports.
- Keep ordinary executable and imported local-engine evidence first. For exact generic bootstrap names (`Launcher`, `Start`, `Bootstrap`, `LaunchGame`) without graphics evidence, inspect same-directory executable peers. Require matching architecture, bounded candidate count/size, containment after symlink resolution, and agreement on the renderer. Exclude common installer/tool names. Conflicts remain unknown.
- Route private/store installs, Steam creation/deferred detection, and Recommended setup through this shared detector. Keep the selected launch executable unchanged, including anti-cheat entry points.
- Unknown APIs now use provisional Compatibility rather than silently asserting DirectX 8–9. The installer log states when detection is inconclusive.

## Existing installations, preservation and Undo

Historical configs do not distinguish an automatically selected mode from an explicit player choice. Do not batch-rewrite them. The shared Graphics picker offers **Check graphics requirements**, reports evidence, and offers **Use [mode]** only when evidence exists and differs. This is a review-only migration until the user applies it through the existing journaled settings path. Recommended setup also receives the improved evidence and continues to respect confirmed gameplay.

Checking does not write settings, files or launchers. Applying retains the current program, game content, saves and other settings; normal launcher hash protection rejects manually edited launchers. Undo through the existing change history or select the previous mode. No installed applications were updated during this investigation.

## Verification and limits

Synthetic tests cover delay imports, bootstrap handoff, conflicting siblings, ordinary-program isolation, local engine cycles, direct evidence precedence, symlink/architecture rejection, and confirmed-mode recommendation preservation. A conditional regression reads the actual installed Rocket League files. This verifies detection, not gameplay or anti-cheat compatibility. RVA delay imports are supported; historical VA-based descriptors remain unsupported. Other bootstrap names and cross-directory handoffs remain unknown rather than triggering unrestricted tree scans. Runtime strings are heuristic evidence, not proof that a particular rendering path executes.

Avoid repeating these unsuccessful assumptions: a launcher is necessarily the renderer; no graphics imports means DirectX 9; 64-bit means modern DirectX; or scanning every adjacent DLL identifies the active renderer.

Validation: `swift test` built the app and completed 201 tests, 6 skipped, 0 failures. All four EngineGraphicsTests passed, including the installed Rocket League regression. An initial targeted run overlapped a source edit and tested the previous fallback against updated expectations; the subsequent complete build/run passed. The first build of the review UI exposed use of an internal helper; it was corrected to resolve the managed C: path through public APIs before final verification.

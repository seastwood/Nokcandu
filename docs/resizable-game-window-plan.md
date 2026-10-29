# Implementation plan: resizable windows for fullscreen games

Prepared October 29, 2026. Status: planned, not implemented. Builds on the [verified feasibility constraints](investigations/windowed-fullscreen-feasibility-2026-10-29.md).

## Product outcome and scope

A player selects Windowed in Nokcandu, starts their Windows game normally, and gets a movable, resizable Mac window. The game can continue believing it is fullscreen at a fixed internal resolution. Resizing scales the complete image; menus, aiming and cursor capture remain correct. Command-Tab, minimization and other desktop windows continue to work without changing the Mac's display resolution.

Build shared infrastructure for applicable Wine games and expose capability based on the actual engine/renderer. Do not promise universal compatibility: graphics APIs, launchers, protected games and unusual input/display code can require adapters or remain unsupported. Native Mac games are a separate capability and must not be described as covered by the Wine implementation.

The existing borderless helper and Winecfg registry toggle cannot supply this feature. The native Mac driver disables the virtual-desktop option; a true solution may require a reproducibly built Wine/runtime extension. This is the first engineering risk to retire.

## Architecture to prove

Use three separate dimensions: game render resolution, outer window size in Mac points, and backing pixels at the current display scale. The game resolution stays fixed during ordinary drag-resizing; the presenter scales its completed image. That avoids requiring games to recreate their render targets continuously.

Proposed responsibilities:

- **Virtual display context:** a process/desktop-scoped logical monitor, mode list, display bounds, fullscreen ownership and mode changes. It must prevent a contained game from switching the physical Mac display. Determine the required Wine server/Win32/mac-driver work with the prototype; do not assume environment variables can virtualize these APIs.
- **Presentation backend:** a regular Mac window with a GPU-scaled output surface. Prefer existing renderer/driver surface integration and shared GPU resources where available. Validate synchronization, ownership, frame pacing and cross-process drawing. A screenshot/recording preview with forwarded input is not the default architecture.
- **Geometry/input service:** one versioned transform connecting Windows coordinates, game pixels, the scaled image rectangle and Mac points/backing pixels. Presentation and input consume the same geometry snapshot. It handles absolute clicks, relative motion, warps, confinement, cursor visibility and focus transitions.
- **Session controller:** owns the target process group, virtual display, presenter and recovery state. Follow verified child/mod restarts and distinguish actual game windows from launcher browsers, installers, dialogs and services. Cleanup restores normal behavior when the game exits or fails.
- **Capability report:** runtime identity plus renderer/API and tested features, such as fixed-resolution containment, live scaling, relative input and multiple windows. Unknown engine versions must not load ABI-dependent integrations by guesswork.

Likely source additions are `WindowPresentation.swift` and `WindowPresentationCapabilities.swift` in NokcanduCore, a native presentation/geometry module, and a separately built Wine Mac-driver/runtime patch set if the spike establishes that requirement. Exact boundaries are a prototype decision, not a claim that those interfaces already exist.

## Milestone 1 — baseline and decisive prototype

1. Preserve current working game settings and record the installed engine/renderer identities. Work in a disposable test environment; do not experiment by replacing every installed game's driver.
2. Add small source-built Windows probes: a fullscreen image with corner click targets, a relative-mouse scene, and a program that changes display mode. Include GDI, then one real graphics API.
3. Prototype a native Mac-driver/virtual-display route first. Evaluate a renderer-specific route only if necessary. Identify exactly which layer supplies logical display isolation, a fixed-size game surface and outer-window scaling.
4. Demonstrate a fixed internal resolution inside a smaller Mac window, then repeated resize, move, minimize/restore and Command-Tab. Confirm the game still reports its internal fullscreen dimensions and the Mac display remains unchanged.
5. Verify a real title using the same route; Chrono Trigger is a useful OpenGL/media case after a synthetic probe succeeds. Use another graphics route only after establishing the first one.

**Exit gate:** complete picture, corner clicks and relative input remain correct during/after resizing, with measured performance and no global display changes. If the installed runtime cannot support this without driver work, deliver a working custom-runtime spike before proceeding to product UI. Merely displaying a resized screenshot or adding window borders does not pass.

## Milestone 2 — maintainable runtime and presentation implementation

- Build the required Wine changes from pinned source, preserving a patch series, source/license notices, build instructions and artifact hashes. Honor upstream licenses; do not redistribute proprietary renderer code as part of an assumed open-source permission.
- Package a versioned optional component/capability rather than silently replacing working engines. Provide atomic installation, verification and a tested engine rollback path.
- Implement the real normal-window lifecycle, output-surface allocation and synchronization. Release resources on close/crash; handle renderer device loss and game-requested resolution changes explicitly.
- Keep the game's internal resolution separate from resize events. Start with Fit/letterboxing, then implement Stretch as an independent scaling policy.
- Record concise diagnostics: selected versus active backend, virtual dimensions, actual window/content rectangle and fallback reason. Do not log credentials, raw launcher arguments or account/session data.

**Exit gate:** repeatable cold launch and rollback through a normal generated app; no temporary developer command required.

## Milestone 3 — input, focus and resize correctness

For Fit, compute scale `s = min(windowContentWidth/gameWidth, windowContentHeight/gameHeight)` in consistent units, center the displayed image, then invert that transform for absolute input. Stretch uses independent X/Y scales. Account explicitly for the Windows/macOS Y-axis conventions and Retina backing scale.

- Letterbox areas must not send out-of-range game clicks. Clamp/release only as the game's requested capture policy requires.
- Preserve relative/raw input semantics; outer-window size must not unexpectedly change aiming sensitivity. Transform cursor warps and absolute position queries consistently.
- Remap the game's actual clip request into the displayed game area; release capture when unfocused and restore it on reactivation. Reuse the existing input code's tested behavior where appropriate, without creating competing re-centering loops.
- Publish geometry changes atomically during live resize, monitor moves and DPI changes. Keep titles, close controls and the outer resize border outside the game's client-coordinate system.
- Test menu-to-match transitions, movies, cursor hide/show requests, multi-button mice, trackpad and controller focus. Do not silently turn Raw Mouse Capture on.

**Exit gate:** automated corner/edge/center targets and continuous relative motion stay aligned across repeated resizing and app switching. BC2's previous offset/cropping sequence is a required regression case before claiming BC2 support.

## Milestone 4 — renderer coverage and capability gating

Expand one route at a time: the chosen initial API, then remaining applicable OpenGL, DirectDraw, DirectX 8/9, DXVK/Vulkan, DXMT and D3DMetal routes. The best order depends on the spike's ownership of their output surfaces. DX8 bridges and embedded video presentation are separate test cases.

For each route, verify startup, video, a playable scene, relative/absolute input, live resize, minimization, multiple displays and performance. Multi-process swapchains and child windows require explicit coverage. A pass on one route does not certify another. Offer a clear explanation for unsupported combinations and retain the player's current graphics backend rather than silently selecting a different one to enable window mode.

**Exit gate:** an explicit support matrix drives the UI. Full universal support is not a release criterion that can honestly be guaranteed; broad tested coverage is.

## Milestone 5 — saved settings, profiles and interface

Introduce a versioned per-game presentation preference with:

- Mode: Game default, existing Fullscreen (Borderless), and the new contained Windowed mode when supported. A game-native window adapter may be offered separately where verified.
- Internal resolution: named presets plus validated custom dimensions within backend limits.
- Resize behavior: Fit initially, optional Stretch; optional integer scaling only once supported/tested.
- Local outer-window position/size, validated against connected displays so a saved window cannot reopen offscreen.

Integrate with `CustomGameConfig`, `HostedSettings.Settings`, the Display UI and profile preview/apply/export. Share mode, render resolution and scaling policy in profiles; keep monitor identity and absolute desktop position local. Old profiles missing the field preserve the current setting. Explicit Game default clears only the owned presentation setting. The legacy unused `virtualScreen` fields are not proof of implementation and must not silently enable this feature when loading older test profiles.

Use the existing change journal and settings/restart flow. Validate conflicts with Mac resolution switching, generic borderless enforcement and game-specific display recipes before applying. Explain the conflict and produce a reviewable change; do not leave two helpers fighting over the same window.

**Exit gate:** settings survive save, profile round-trip, normal restart, engine update and Undo without changing unrelated game or input choices.

## Milestone 6 — launchers and fresh installations

Integrate the presentation session into normal generated launchers for standalone games, shared Steam, EA, Ubisoft and Battle.net as each is verified. Attach it to the actual game launch, not every process in the shared prefix.

An already-running launcher can start games with an older desktop/environment. Make the new presentation configuration part of the running-session comparison, then use Nokcandu's scoped Apply and Restart flow when necessary. Start the selected game in the same action. If independent per-game contexts cannot coexist in one shared host, state that limitation and offer a scoped restart rather than affecting another running game silently.

Test games started by URI, DRM handoff, launchers spawning helper processes, mods restarting executables and launchers updating themselves. Do not remove authentication, anti-cheat or security checks to force support.

Fresh installations get the same component and launch paths as upgraded installations. Preserve manually edited launchers; migrate only recognized generated scripts. Do not enable the new mode for existing games without a user/profile choice.

**Exit gate:** one-click normal game launch with retained presentation settings across cold launcher starts, updates and game/mod restarts on each supported launcher.

## Milestone 7 — release validation and rollout

- Unit tests: geometry/inverse transforms, aspect ratios, Retina scale, bounds validation, legacy profiles and capability decisions.
- Integration tests: real display-mode isolation, synthetic pixel/click probes, process ownership/cleanup, launch handoffs, device loss, crash recovery and Undo.
- Real game matrix: Chrono Trigger, BF1942, BC2, an ordinary DirectX 11 game and representative DirectDraw/Metal routes where available. Record edition, engine, renderer, hardware and exact tested layers.
- Performance: compare the same gameplay scene with the baseline. Record median/p95/p99 frame times, input latency, CPU/GPU load, sustained M4 Air behavior and audio continuity. Measure before agreeing to a numeric overhead/latency target; do not infer success from menu FPS.
- Roll out as opt-in experimental support for verified combinations first. Promote individual combinations after repeated cold launches and resize/focus tests. Keep a one-step return to Game default and runtime rollback.
- Update engineering learnings, compatibility notes, the support matrix and user documentation with observed results. Passing code checks is separate from visual/gameplay verification.

## Delivery sequence

First deliver a working fullscreen-in-a-window prototype and its evidence. Next make its runtime/input/presentation integration reproducible and recoverable. Then add saved settings/profiles and real launcher handoffs. Expand renderer coverage, complete the regression/performance matrix and ship the supported subset. This sequence avoids shipping a polished settings control before its underlying capability exists.

No schedule estimate is committed before Milestone 1 establishes the required runtime work. The next concrete implementation task is that isolated vertical prototype, not adding the picker alone.

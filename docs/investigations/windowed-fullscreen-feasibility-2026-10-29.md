# Fullscreen games inside a resizable window — October 29, 2026

Status: feasibility investigation; no new presentation backend or user-facing mode implemented.

## Requested behavior

The game believes it is fullscreen at a chosen internal resolution. Nokcandu presents that output inside a movable, resizable Mac window alongside other apps. Resizing scales the output while preserving correct mouse targeting. This is more than adding a border or asking a game to switch to its native windowed mode.

## Confirmed constraints

The user observed Wine's virtual desktop control greyed out. Wine 10's official [winecfg graphics configuration](https://github.com/wine-mirror/wine/blob/wine-10.0/programs/winecfg/x11drvdlg.c#L95-L122) explicitly returns false from `can_enable_desktop` for `winemac.drv`, then disables the checkbox. Nokcandu's current engine uses that native Mac driver. Exposing the same registry checkbox in Nokcandu would not establish a supported working feature.

Wine's [Explorer desktop implementation](https://github.com/wine-mirror/wine/blob/wine-10.0/programs/explorer/desktop.c#L1105-L1216) accepts a named desktop with dimensions and creates a virtual Windows desktop. The existence of `/desktop=name,widthxheight` does not establish native Mac-driver support or arbitrary live scaling. Earlier conversation wording implying this was readily available on this engine was too broad.

Nokcandu's existing borderless helper in `Resources/borderless/window.c` removes frame styles and resizes the target window to its monitor. It does not provide an independent emulated screen, renderer scaling, or corresponding input-coordinate transformation. BC2's prior cropped display and menu-pointer offset are concrete reasons not to treat blind window resizing as a universal solution.

## Viable implementation direction to prototype

A shared presentation subsystem would own a fixed internal game resolution, a Mac window, scaling and the inverse mapping from window coordinates into game coordinates. Initially preserve aspect ratio with letterboxing; an optional stretch policy can be added with the same input transform. Moving between Retina/non-Retina displays must not change logical game coordinates unexpectedly.

The first prototype should use a disposable test app/environment and one supported renderer. Verify that it can keep a game fullscreen internally, show the entire image in a smaller outer window, resize repeatedly, and retain correct clicks and relative aiming. Merely adding a title bar to a fullscreen window does not meet this acceptance test. Whether the appropriate implementation belongs in the Wine Mac driver, a renderer integration or a combination remains unverified.

A capture-and-forward preview is not assumed equivalent: latency, frame pacing, input delivery, hidden-window behavior and permissions would all need separate validation. Switching the whole engine to another display driver solely to enable a checkbox is likewise not an established solution for the existing Metal graphics paths.

## Product integration once a backend is verified

- Keep the setting in Display with the game's saved setup and saved/shared profiles. Provide internal resolution and aspect-ratio policy independently of the Mac's screen resolution.
- Explain support based on the active engine and renderer. Native windowed mode, borderless fullscreen and contained fullscreen are distinct capabilities; only expose an actionable option when its backend is available.
- Do not change defaults for working games. Applying/removing the mode must preserve unrelated graphics, component, display and input choices and use the normal backup/Undo system.
- Games launched by Steam, EA or Ubisoft may inherit their launcher's existing Windows desktop/environment. Test the real launcher handoff and offer the normal scoped restart when needed, including unsaved-game notice. Per-game control must not silently change another running game's presentation.
- Built-in game settings adapters can offer ordinary windowed mode where tested, but their availability must not be presented as universal fullscreen containment.

## Required coverage before release

Test the supported subset of DirectDraw, DirectX 8/9, DirectX 10/11, OpenGL, Vulkan and Metal-backed routes individually. Include cold launch, movie playback, actual gameplay, repeated resize, click alignment at all corners, relative aiming, focus loss/Command-Tab, cursor capture/release, multiple monitors, Retina scaling, audio, minimization, mod/game restarts and restoring Game default. Recheck performance and latency on the fanless M4 Air.

No game/runtime settings were changed during this feasibility investigation. There is no verified universal mode to enable yet. This record defines the engineering work needed before promising that behavior in Nokcandu.

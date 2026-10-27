# Compatibility components

The feature is optional and per standalone managed game. No defaults or existing game installations are migrated. The generic components reproduce the renderer, shader-library and window fixes tested during BF1942 troubleshooting; local mouse and busy-match performance still require in-person verification.

| Profile ID | Files/settings owned | Source |
| --- | --- | --- |
| `directx9-extras` | Matching-architecture `d3dx9_43.dll`, `d3dcompiler_43.dll` beside the selected program; individual native/builtin DLL rules | Microsoft June 2010 DirectX redistributable, SHA-256 checked |
| `d3d8to9` | Local `d3d8.dll`, individual d3d8/d3d9 rules, `legacyD3D9` flag selecting existing `renderer/dxvk/wine` | crosire/d3d8to9 v1.16.0, SHA-256 checked |
| `borderless` | `C:\nokcandu\borderless\launcher.exe` and `window.dll`, matching program architecture; `borderless` flag | Nokcandu C sources built with pinned Zig |

The selected game executable is unchanged. The launcher wraps it only when borderless is enabled; its working directory and original arguments are preserved. The injected window helper stays inside the launched process, ignores minimized, owned and tool windows, and does not change the display mode or force the window above other apps. It follows restarts of the same executable, not arbitrary launcher children. This is a compatibility option, not a guarantee for every game.

`CompatibilityFixes` keeps installation manifests and conflict-aware file journals inside the game's state directory. Original files are backed up before replacement. Network downloads and extraction finish before game files change; the game and settings are rechecked before committing. A per-app reservation prevents simultaneous component operations. Interrupted installations retain an Undo record. Undo validates owned files before touching settings; it restores only that component's DLL rules and switches, preserving other components and unrelated settings. An external edit blocks Undo rather than being overwritten.

Profiles name built-in IDs only. Preview lists component installs and unavailable components. Installed component settings remain active when applying/undoing a settings profile; remove them with their own Undo. A program change is blocked until its components are removed. Shared Steam/Battle.net/other launcher environments need explicit per-program routing before support can be enabled.

The BF1942 menu-size executable copy and its `.con` settings are deliberately not generalized. Future settings recipes should use allowlisted game-specific paths/keys with backups. Any future executable correction needs an explicitly approved built-in recipe with a full-file fingerprint and an untouched original, never bytes or scripts supplied by a community profile.

Validation: Swift unit tests cover grouped DLL rules, component references, old settings decoding, launcher quoting, conflict refusal, file restoration and independent component Undo. Both Windows architectures were tested against an isolated Win32 probe: window bounds matched its monitor and quoted arguments survived forwarding. Microsoft-hosted extraction was checked with the bundled tool. These checks do not establish gameplay compatibility for all games.

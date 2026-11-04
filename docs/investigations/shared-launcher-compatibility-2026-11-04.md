# Game-local compatibility components in launcher environments — 2026-11-04

## Request and scope

The compatibility component installer unconditionally rejected Steam, Battle.net, EA and Ubisoft game shortcuts because they did not own private Windows environments. The user asked for systematic support across launchers, not a one-game override. The originally mentioned EA BF1942 installation had intentionally been uninstalled; its stale records and another discovered copy were left untouched. Verification uses disposable fixtures, not the user's game content.

The existing private component path remains. A shared-game backend now resolves a game's registered installation and program, installs applicable local components beside that program, and records ownership in the game's small Nokcandu app. It uses the same pinned component downloads, extraction, PE checks, file/settings journals, pending queue and profile IDs. Neither client executables nor global DLL override settings are modified.

## Isolation and installation

Registered roots must be present, dedicated game folders. Drive/library roots, Windows data, client-containing directories, overlapping registered games and symlink escapes are rejected. Unlike whole-folder removal, compatibility validation allows games inside a client's own games/ subdirectory: the client must not be inside the selected game root. Windows drive aliases and canonical Mac paths refer to the same checked program.

Program for fixes lets the user select a program within the registered game folder without changing the launcher's launch program. Existing component receipts bind subsequent operations to the original program, so renaming a library entry or discovering another EXE cannot redirect installed fixes. Changing that selection with installed components requires their Undo. If the registered content or program changes unexpectedly, operations stop and preserve files.

Downloads precede mutation. The program hash, current settings, closed-session evidence and ownership are rechecked before installation. An active or unknown shared environment defers queued fixes until all its programs close. Cinematic installation/removal now uses the same shared-session safety gate rather than only a Steam-specific check.

## Applying rules when a client launches its game

`program-fixes.tsv` resides beside the host's shared helper. Rows have stable owners and complete program paths; basename matching is deliberately unavailable. The native helper reads the matching game's renderer/DLL settings before Wine initializes its DLL search paths. Client processes and other paths with the same EXE name retain their own settings. The writer serializes atomic updates across processes and preserves other owners' rows. Game-local cursor/window records and log paths follow the selected app; microphone policy remains governed by the existing game setting and live policy files.

The direct EA shortcut also receives the same component environment. Existing owned launchers migrate through their saved hashes; manually edited launchers remain protected. Normal maintenance recreates routes from game receipts and settings. No compatibility component is automatically enabled just by updating Nokcandu.

## Applicability and real limits

Microsoft shader compiler, DirectX 9 extras, 32-bit DirectX 8 translation, matching bundled VC libraries, DXMT cross-process mode and the cursor component use this shared backend where their normal requirements are met. OpenUA settings and BF1942 software sound retain their actual game/data checks; they are not applied to unrelated titles. DirectX 8 translation still requires the legacy renderer and Older 3D mode.

The borderless Windows wrapper currently supports the direct EA game launch method. Client-managed Steam/Battle.net/Ubisoft starts cannot yet be wrapped by that component; the UI states this specific requirement instead of rejecting every component. The existing private-environment IPX components still require private networking/provider setup and are not claimed to be isolated in shared clients. LAV/PhysX remain explicitly environment-wide components. The separate BF1942 executable/menu-copy recipe remains restricted to verified standalone binaries; this change does not patch EA game executables or alter authentication.

## Profiles, settings and Undo

Shared component DLL rules are derived from their receipts rather than written into client settings or leaked into a Steam game's base config. Profiles capture enabled built-in IDs, not local paths, DLLs or recovery-only records. Newly captured shared-launcher profiles use schema 3; private profiles retain schema 2 and older schemas remain readable. Older app builds reject schema 3 instead of applying the new per-game settings with their old shared-client behavior. The app and catalog validator accept schemas 1/2/3 together; CI checks this allowlist as data alongside the component IDs. Applying a profile uses the same component installer. Borderless IDs are not duplicated. A failed installation is inactive, visibly needs recovery and cannot be published as a working component; Undo remains available.

A related Battle.net profile path previously applied graphics/environment settings to the client. These now live on the selected game, are captured and restored independently, and use exact-program routing. Steam profile extra settings likewise stay per game. Profile Undo restores only settings it actually applied, preserving later unrelated client preferences. Existing per-game Battle.net choices retain their meaning; complete-path routes run after the legacy renderer map for compatibility with existing helper generations.

Undo validates file ownership and the currently registered root, reverses only the selected game's files/settings, removes its component rules and keeps other games' routes and preexisting components. Shared architecture-specific borderless helpers are checksum-owned and retained for other games; normal maintenance/Repair can refresh them when idle. Choosing Game default in the EA window-style setting undoes its borderless component through the normal queued executor. Restore/revert the app for infrastructure rollback; use each component's Undo for content changes. Game content, saves and existing explicit settings are otherwise preserved.

## Verification and comparisons

- Disposable EA/Ubisoft/Battle.net/Steam fixtures exercise component installation, routing, Undo and unchanged client configuration.
- Separate fixtures cover identical program names in different game roots, the normal nested client/games layout, a renamed Steam game remaining bound to its original program, symlink escape rejection, edited-launcher protection, inactive recovery records and profile capture.
- Per-game Battle.net profile settings and Undo preserve the client's configuration and a later unrelated client performance change. Steam profile environment settings apply through the game route and undo independently.
- A real pinned-package shared BF1942 profile fixture installed all five existing shader/DirectX/window/sound components, verified their 32-bit DLLs, captured valid portable IDs and undid them while restoring sound and preserving the client. This checks integration; it is not gameplay verification of a real store copy.
- `Tools/program-fixes/probe.py` compiled a synthetic client, child game and DLL with the pinned compiler. Under both Wine 10 and 11, both i686 and x86_64 child games received their native-DLL rule while the parent client retained its builtin rule before and after launch. Only fresh disposable prefixes were used. CI now runs this probe with its existing pinned compiler/runtime matrix.
- The first fixture reused a global hosted-settings journal, which caused the removal test's isolation assertion to fail. Fixture journals now use a guarded test-only default root, and verified temporary-only artifacts were cleaned up. The corrected removal regressions passed. The first native build also caught a helper-name collision with the existing input path matcher; a distinct full-path matcher fixed it. Neither failed comparison was installed.

Final local verification: 355 tests passed, with 16 expected optional checks skipped. The production package built with both required custom Wine driver and native-IPX resources, and the five-component shared profile integration test passed again against that package. The installed app passed deep/strict signature verification. Its Counter-Strike: Source page showed the selected program, enabled shader/DirectX 9 installs and component-specific restrictions; no game component or setting was changed during UI inspection. An existing EA compiler-file ownership warning was preserved rather than overwriting the changed DLL.

The companion catalog validator was published as `Nokcandu-Profiles@8f576f2`; its 10 tests and GitHub validation passed. The app's ID/schema check also passed against that published validator. GitHub app CI and the revised engine-watcher results are recorded after the push.

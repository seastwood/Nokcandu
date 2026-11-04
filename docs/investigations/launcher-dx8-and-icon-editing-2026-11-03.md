# Launcher architecture and icon editing — 2026-11-03

## Confirmed problem and scope

The Moongamers BF1942 installation selected `Borderless1942.exe`, a 64-bit launcher, while adjacent `BF1942.exe` is 32-bit and directly imports `d3d8.dll`. Eligibility inspected only the launcher. The user changed the program manually and could install the fix.

The shared DX8 installer now accepts a 32-bit selected program as before, or exactly one adjacent 32-bit EXE directly importing DirectX 8 behind a 64-bit launcher. The bounded search stays in the managed folder and rejects escaping executable symlinks and ambiguous matches. DLL installation retains the selected launch program and logical prefix paths for external content. Fresh and existing installations use this check immediately, with no automatic game-content mutation. Fix receipts, profile IDs and component Undo remain unchanged. This is not a BF1942-specific override.

## Independent icons and Undo

Windows-game headers provide Edit Icon → Choose Icon from EXE. The chosen EXE supplies artwork only; game program, arguments, settings and launcher remain untouched. Extraction/conversion finish in a temporary folder before mutation. Existing icon resource filenames are retained so generated game identities can copy the artwork on subsequent launches. A running game's Dock icon can wait for its next launch. Native Mac app bundles are excluded.

An app-local `game-icon` journal retains originals. Restore Original Icon validates ownership before Undo and refuses later manual changes. Icons/source EXEs are not embedded in shared settings profiles. Existing installations need no migration until the user explicitly chooses an icon.

## Verification

Three regressions passed: 64-bit launcher/32-bit DX8 target and ambiguous/wrong-API/escaping alternatives; repeated icon edits, exact Undo and manual-change protection while preserving launch settings; installed BF1942 inspection and actual icon extraction into a disposable app. Full suite: 332 tests, 14 optional skips, zero failures. No user game content changed during tests. Final build/UI evidence is recorded below.

## Initial reports and subsequent findings

The user deferred BF2 fullscreen Spaces input loss: input works initially and windowed, but keyboard/mouse stop after swiping away and back. Bindings remain present. No focus patch was made; activation recovery is an untested hypothesis.

After selecting BF1942.exe and installing DX8 compatibility, the user reported two menu crashes at `0x007fbeb2`, reading address `0x8` with null EBP. The DX8 adapter loads. Resolution changes precede the crash in the log, which is correlation, not a confirmed cause. The Moongamers EXE differs from the previously verified menu-copy source; its allowlist must not be bypassed. The user also reproduced the crash without resizing/fullscreen, weakening that hypothesis. No binary patch, global permission change or game-settings reset was made for this crash.

## Resolution-only receipt incorrectly blocked changing programs

The existing Moongamers display receipt had `recommended: false`, `ownsBorderless: false`, and identical previous/applied programs. It owned resolution settings only, yet the generic save guard treated any display receipt as ownership of the launch program. Selecting Borderless1942.exe also failed the filename-based BF1942 recognition check, hiding its Display controls and Undo. Pending settings retained the user's requested program but could not apply it.

The guard now binds program selection only for the verified recommended menu-copy recipe. Resolution-only Undo preserves any subsequently selected program. BF1942 recognition adds the known Borderless1942.exe wrapper and still requires the game EXE plus Mods/bf1942/Settings content; Display remains visible for existing receipts and Undo can validate against the receipt's original managed folder. One additional regression verifies resolution-only apply, a switch to a 64-bit borderless wrapper, retained resolution and successful Undo without reverting the wrapper. Nine focused launcher/icon/profile tests passed after this change. Existing queued program requests can retry through the normal saved-settings path; no pending request is discarded.

## Profile entry-point parity

Source inspection confirmed that Notes → Restore called the synchronous settings-only profile API. Game Profiles used separate UI-owned component loops. Both product paths now call the shared asynchronous `Profiles.applyComplete`: settings, refreshed eligibility, cinematic/compatibility components and game display. Unsupported components/download errors return explicit partial-result reasons, while completed steps retain their receipts. Profile Undo tracks newly added compatibility components and preserves components installed before application. The notes confirmation now lists components to install. Public UI does not call the settings-only API directly.

A regression installs an actual non-downloading shared component, checks its receipt and environment, verifies a deliberately incompatible DX8 request is reported, reapplies the profile, then verifies the second Undo retains the pre-existing component and the original Undo removes it and restores settings. The first fixture omitted its executable Wine stub, so Undo's existing Windows-environment validation refused it; the complete disposable environment passes. The settings-only API remains for lower-level callers/tests. Cinematic/LAV installation retains its own component Undo; it is not removed by synchronous profile Undo.

## Confirmed BF1942 software-sound workaround

The active noken profile had hardware sound enabled. With BF1942 confirmed closed, only `game.setHardware 1` was changed to `game.setHardware 0`. Exact original bytes and before/after hashes were retained in the game's local Diagnostics directory. This is a reversible per-installation diagnostic, not a confirmed fix or a new global default. The user was asked to retry the menu. If unsuccessful, restore only when the file still matches the diagnostic's after-hash; preserve later user edits. Do not commit this local backup.

A full-suite comparison rejected the first broader directory-only recognition attempt: unrelated programs beside BF1942 must not gain its settings or game-specific cursor restriction. Known launcher names plus content validation are retained, with Borderless1942.exe added explicitly. Receipt fallback is used only for validating owned Undo paths, not to offer game-specific recipes to unrelated programs. The final profile operation also applies native IPX frame settings even when the profile contains no display recipe; the existing registry/frame/Undo regression exercises this entry point.

The user confirmed that the one-setting software-sound comparison resolved the menu crash and allowed joining an online match. The exact failure mechanism within the game's hardware-audio path is unproven; resizing and generic DirectX failure were not established. The existing original settings backup is retained locally. No game executable was patched.

An optional built-in `bf1942-software-audio` component now changes only `game.setHardware` in BF1942's safely resolved active player profile. Route traversal, outside-folder links and unfamiliar hardware values are refused. It uses setting-key journal ownership, so Undo preserves later volume edits. This remains specific to BF1942 and is not a global software-audio default. Reapply after selecting another player profile. Profile creation captures an already-working software setting even when it was selected manually; profile application installs the component on the recipient's own active profile. No machine-specific player path is shared. Fresh installs change only when explicitly applying this component/profile; existing games' settings stay untouched otherwise. The regression checks install, profile capture, later volume edits, Undo and traversal rejection.

## Final combined verification and installation

The final full suite passed 335 tests, 14 optional skips, zero failures. The production app was built with both supported Wine drivers and native IPX required, then installed with the app-only recovery helper. The installed app passed deep/strict signature verification. Running games were not terminated for the app replacement.

Visible checks in the installed app confirmed Edit Icon → Choose Icon from EXE and Restore Original Icon, the BF1942 software-sound option, and reachable Undo BF1942 Display Settings on the Moongamers page. The menu was left closed, without changing a launch program or applying a profile to a live game. Actual artwork extraction/conversion and preservation of launch settings were tested in a disposable app; the UI check did not choose artwork for the user. Existing queued setting requests were retained.

The native-IPX frame regression uses a current fake helper/package receipt to isolate frame selection without downloading or repairing an obsolete helper. Newly restored legacy-IPX dependencies needed by a pre-existing native-IPX component are retained by profile Undo. Component/profile migration does not change packet permissions or adapter choices. No microphone helper, Wine driver focus patch, or BF1942 executable patch was included in this work. BF2 Spaces input loss and the previously disclosed microphone-Off prompt remain deferred/unresolved.

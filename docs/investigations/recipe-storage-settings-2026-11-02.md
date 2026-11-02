# Recipe storage and user settings — 2026-11-02

## Confirmed cause and scope

Zero Hour installed with the shipped recipe could not move its game files to an ExFAT library. `GameMover.gameFilesFolder` only consulted `CustomGameConfig`; recipe installations deliberately have no custom configuration. The recipe already declares its dedicated content directory. Settings sections used the same custom-only condition, hiding controls even when the underlying engine could support them.

The shared correction covers shipped standalone recipes, currently Zero Hour and Worms Armageddon. Shared store libraries retain their store-owned storage controls. ExFAT hosts game content; the Mac app, Wine engine and private Windows environment remain on a filesystem supporting their links and permissions. This is a filesystem requirement, not a recipe restriction.

## Implementation and preservation

- Resolve recipe content from its declared `gameDirectory`, with dedicated-directory guards. Zero Hour's `SharedSupport/GameFiles` and its existing relative C-drive link remain valid after relocation. Give external recipe folders game-specific names to avoid multiple `GameFiles` destinations. Relative links are resolved relative to their containing directory, including return-to-Mac operations. Reject destinations inside the source folder. Restore the original link if installing the return copy fails.
- `RecipeSettings` records graphics, an optional Windows program, additional arguments, environment overrides and microphone choice separately from recipe data. Empty settings preserve the original recipe launch command. Zero Hour still extracts its official packed launcher and runs `Launcher.dll` through .NET; selecting another program is an explicit override.
- A reversible marked launcher block reads settings and existing `perf.env`. Only the final game command receives extra arguments/program selection. Shell quoting uses the existing argument parser and literal value quoting. Empty arrays use macOS Bash 3's nounset-safe expansion. Changing graphics clears previous renderer selectors, replaces only renderer DLL rules, and preserves recipe-required runtime/ICU overrides. Missing graphics layers produce an explicit error rather than saving a broken mode.
- Ownership fingerprints strip both helper and recipe additions. Refresh upgrades only recognized, closed launchers, preserving display patches and user choices. Manually edited launchers remain untouched. New recipes and existing installations use the same refresh/save path.
- Performance and microphone controls are shown for recipe installations. Capture defaults Off; setup tools and Wine children use the same shared enforcement as ordinary installations. Launch-setting edits preserve the separate current microphone choice.
- Profiles include effective graphics, shareable recipe/user environment, arguments, selected C-drive program and disc requirement, plus existing performance/mouse/fix fields. Applying profiles to a recipe preserves local-only values and microphone consent; Undo restores the previous recipe settings. Profiles do not bundle proprietary runtimes/game files or grant macOS permissions. Required recipe components still come from installation/repair.

## Verification

`RecipeSettingsTests` checks both content layouts, out-and-back relocation, relative links, bytes accessible through the unchanged Windows path, exact launcher fingerprint normalization, manual-edit protection, microphone opt-in, renderer dependency preservation, and profile apply/Undo. A real Bash subprocess with a fake Wine command verifies arguments with spaces, literal command-substitution text, environment overrides, performance settings, alternate program selection and empty defaults. It makes no microphone or game calls.

Full suite: 239 tests, 10 optional tests skipped, zero failures. Read-only checks of the installed Zero Hour and Worms apps confirmed both launchers are recognized and proposed migration normalizes to their original bytes. Actual post-move startup verification is recorded below when completed; new renderer modes and alternate game programs are not gameplay-validated by these tests.

## Undo

Use **Bring Game Files Back to This Mac** to reverse a content move; the external drive must be connected. Choose **Recipe Defaults**, then **Save Changes**, to clear launch overrides. Performance, display and microphone retain their own controls. Profile trials have their normal Undo. Settings/launcher writes are journaled; no saves or game executables are rewritten by this feature. Existing manually edited launchers require an explicit restore before managed settings can be applied.

### Installed-app verification

Moved the user's closed Zero Hour installation through **Move To → Elements**. All 555 files (3,084,135,426 logical bytes) matched their pre-move SHA-256 checksums. The original local content directory is a link to the external dedicated game folder; the existing relative Windows path still resolves. The recipe's `--check` completed successfully. The first actual Play reached macOS's removable-volume approval wait: the privacy log attributes the request to Zero Hour's native app entry, with Python performing launcher preparation. The user approved removable-drive access and then confirmed the game opened. Startup from the moved installation is verified; new gameplay after this move has not been asserted. No privacy database or consent was changed by the agent.

The live move also exposed a stale size summary: its background task only keyed on the app path, which stays unchanged for a content-only move. It now includes the external-content path, so move/return refresh the displayed storage automatically.

The final signed update was installed while leaving the game running. Nokcandu's refreshed storage summary shows the split correctly: approximately 1.82 GB for the local app/runtime and 3.53 GB allocated on the ExFAT drive (larger than logical content size because of filesystem allocation). Existing restore points were preserved; a restore point that retains the old game content can still consume local storage after a move. Removing restore points is a separate explicit user action, not part of moving game content. The shared code is commit `1519a59`; remote validation is [CI run 41508748671](https://github.com/seastwood/Nokcandu/actions/runs/41508748671), which was queued when this verification was recorded.

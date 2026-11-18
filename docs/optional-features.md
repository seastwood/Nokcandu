# Optional features and update notifications

November 18, 2026. Games, Remapping and Streaming are built-in features selected on the welcome
screen or in Settings → General → Features. These are visibility and service policies, not downloadable
plugins. The app and shared input infrastructure still ship together.

## Behavior and preservation

- Existing installations default to all features visible. Saved tab selection is retained when visible;
  hiding the selected tab moves to the first remaining feature. A single feature has no segmented tab
  picker. All hidden is supported, with a permanent route back to General settings.
- First-run feature selection is quick and does not require a Wine/Rosetta download. Game startup work
  waits until the selection is accepted. The Windows setup checklist remains available when Games is on.
- Hiding Games removes its navigation, menus and game-specific settings tabs/sections. New scans, store
  discovery, game maintenance, drive attachment and Wine/LAV catalog checks are skipped. App update
  checks still work independently. Already-started operations can finish; active games retain status/Quit
  controls, and their save-upload/cleanup behavior remains available when they exit.
- Hiding Streaming removes its navigation and stops host watching/discovery. It neither unpairs hosts
  nor ends an ongoing stream. Active stream controls remain available until it ends.
- Hiding Remapping hides the Controls workspace and menu entries and pauses desktop/app profiles. It
  removes the Steam direct reader's background lifetime listener without changing the user's exclusive
  access preference or resetting capture held by a game/stream reader. Existing profiles assigned to
  games or ongoing streams continue working. This is intentionally different from turning all profiles off.
- Installed game apps, saves, prefixes, paired PCs, stream profiles, controller/keyboard profiles, assigned
  mappings, custom launcher files and engine pins are not removed or rewritten by a feature switch.
  Turning a feature on restores its saved content. Existing auxiliary windows/jobs aren't forcibly closed.

Preferences use `enabledFeatures.v1` in app defaults. The legacy `sidebarTab` values are unchanged
(`profiles` still names Controls). Unknown future feature IDs do not produce invalid navigation.

## Update notifications

The settings gear shows red for an available, unignored Nokcandu version. Otherwise, orange indicates
available game components or store-game updates. Game updates are suppressed when Games is hidden.
Engine holds and in-progress engine trials do not produce another engine-update notice; failed engine
self-tests suppress that candidate as before.

Updates offers **Ignore This Version**, **Notify Again**, **Ignore Current Updates** and **Restore Ignored
Notifications**. Ignoring only clears notification state: it does not pin/install an engine or remove its
manual Update/Try button. An engine notice is scoped to a game host and engine/template version; shared
Steam games share their host. LAV/store updates are scoped to the game and version/build. App update
ignores apply only to that Nokcandu version. A newer version can notify again.

Ignored notices use `ignoredUpdateNotices.v1`. The successful app check's available release and check
date are cached separately from the Wine catalog (`availableAppUpdate.v1`, `lastAppUpdateCheck`), so a
Wine-free workspace keeps its app badge across restarts. Installed/newer app versions discard obsolete
cached releases. A failed network check preserves the last successful result.

## Validation and remaining acceptance

November 18 release acceptance: the user tested hiding features and confirmed that it works. This confirms
the reported UI behavior; it does not establish the remaining live-session and update-notification checks below.

Focused automated checks cover all eight feature combinations, preference round trips and existing-user
defaults, hidden-tab fallback, preserved unrelated settings, profile dependencies/background ownership,
red/orange priority, per-game/per-version ignores, restore, held/failed engine suppression, store notices
without a Wine catalog, successful app-check persistence, and preservation of fixture saves/manual launchers.
The app compiles. An isolated AppKit rendering of the welcome view was inspected for switch alignment and
text wrapping; it does not run controller readers or modify production preferences.

Still requires an installed UI/hardware acceptance pass: toggle each feature and relaunch; verify real
libraries/profiles/hosts return; hide while a game/stream runs and check its input and exit controls; test
Steam capture release/recovery; exercise real available updates and ignore/restore controls. No new signed
build has been installed or published as part of this change. Automated policy tests are not hardware
coexistence or complete UI acceptance.

## Undo

Turn the features back on under General settings and restore ignored notifications under Updates.
For a code rollback, the feature switches only add app-default keys; an older build ignores them and
shows its original features again. It can leave added notification keys in place harmlessly. No game,
profile, pairing or launcher restore/migration is required.

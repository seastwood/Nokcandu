# Idle CPU, space management and moves — November 4, 2026

## Symptoms reported

- Nokcandu used noticeable CPU while idle and periodically stopped responding, then recovered.
- Game apps whose files are on the external drive were shown as 2–3.3 GB each; launchers looked much larger.
- Moving a game to an APFS volume moved only the app; there was no choice of what moves or where, and launchers could not be moved.
- After moving BF1942 (Moongamers), OpenUA and Warcraft III, Nokcandu treated them as unfinished installations and resumed BF1942's install instead of letting a new game be added.
- Logs had no retention limit. No in-app way existed to create an APFS volume on an ExFAT drive.

## Measured causes (on the reporting Mac, 0.12.4 build)

### CPU
`sample` of the idle app (~42% CPU in `top` with the window in front) showed one cooperative thread busy ~70% of the time in `AppModel.refreshRunStates`, every 3 s:

- `HelperActivation.statuses` hashed the bundled helper dylib and every host's installed copy (SHA-256) **on every pass**, and checked every process on the Mac against every Wine host with `proc_pidpath` + `URL` construction (which stats the file system).
- `GameLauncher.launchedGameProcess` checked every process for every game; for launcher hosts the command matcher accepts any non-system program, so it ran `WineTools.owns` (URL work again) for nearly every process, after a `kill(pid, 0)` per row and a `lowercased()` of each command per game.
- `PendingSettingsMonitor.drain` read every game's queue folder (SHA-256 of a path key, `GameLibrary.inspect`, realpath) twice per game per pass even with nothing queued.
- Store discovery rescanned the whole library (and launcher manifests on external drives) every 15 s.
- `@Published` values (`statusUnavailable`, `pendingActivities`, `helperActivation`) were reassigned each pass, re-rendering the window even when nothing changed.

Responsiveness: `GameLibrary.scan()`, `reorganize()` (per-game JSON reads, `NativeGames.missing`, offline folders) and the `updateCount` computed property (reads engine records for every host on each view render) ran on the main thread. With apps on an external drive or disk image that is asleep, these block the UI.

### Space
Measured with `ATTR_CMNEXT_PRIVATESIZE` (bytes not shared with APFS clones):

| Item | Allocated | Private (unique) |
| --- | ---: | ---: |
| Battlefield 2.app (files on Elements) | 2.9 GB | 12 MB |
| The Falconeer.app | 3.1 GB | 316 MB |
| Steam.app | 12.1 GB | 678 MB |
| Battle.net.app | 9.8 GB | 34 MB |
| engine-rollback (each "trying" app) | 1.7 GB | 0 MB (clone of the cached Wine 10 runtime) |
| Restore points (all, on the Mac) | 125 GB | small per point, but sets for moved/removed apps are no longer shared with any app |

- The 2–3.3 GB figures are mostly the Wine engine and setup **cloned** from Nokcandu's engines cache: Finder and Nokcandu's previous allocated estimate counted them in full for every game; the disk stores them once.
- Five apps had been "trying" Wine 11 for days; the roll-back copy is free on the Mac (clone) but becomes a full copy if the app moves to another drive.
- Restore points stay in the old folder when an app moves (clones cannot cross drives), and orphaned sets for moved/removed apps (EA app, Army Men, BF1942, OpenUA, Rage of Mages 2, Warcraft III) kept their blocks on the Mac.
- The Elements drive is ExFAT with **1 MB clusters**: OpenUA's 855 MB of files take 7.2 GB there; Battlefield 2's 4.1 GB take 6.3 GB.

### Unfinished installs after moving
`InstallState.targetApp` kept the pre-move path. `InstallerModel.unfinished()` treats a record without `finishedAt` whose target has no app as unfinished, and starting a game with the same name resumes it. In addition, a microphone-policy refresh and a launcher upgrade that started before the move finished wrote into the old path after the source was removed, recreating a 1 MB "ghost" `Battlefield 1942 (Moongamers).app` (no Info.plist) in the standard folder; the resumed install then wrote `game.json` into it.

## Changes (shared, all games)

**Efficiency**
- Ownership checks are string-only against a cached, symlink-resolved `SharedSupport` path; executable paths are cached for 2 s per pid; command lowercasing happens once per process scan; liveness probes run only for matches.
- Helper SHA-256 is cached by size/mtime/inode; the helper-activation pass looks up process paths once for all hosts and runs only after something starts/stops or once a minute.
- Status checks every 3 s only while Nokcandu is in front; every 20 s in the background and 30 s while a game runs. App launch/quit notifications trigger an immediate (coalesced) check.
- Store discovery: every 2 min in front, 15 min in the background, forced on drive changes and when something starts/stops.
- The pending-settings drain lists the queue root once and skips per-game reads when nothing is queued.
- Library scans, offline-drive checks and the update count run off the main thread; published values are assigned only when they change.

Measured after the change on the same Mac: ~3% CPU with the window in front (one `ps` per 3 s), ~0–0.4% in the background (was 25–42%).

**Space and records**
- Storage shows what an app adds on its own and lists clone-shared engine data separately.
- New Storage → Free Up Space: orphaned restore points, ghost app folders, roll-back copies (Keep New Engine), downloaded installers, and ExFAT overhead per game with a Move… shortcut.
- Automatic restore points: 3 per app (was 5), removed after 30 days (the newest is always kept); restore points follow a same-drive move and are replaced by a fresh one on a different drive (option to keep the old ones).
- Engines tried for 7 days and played since are kept automatically (restore point from before the change remains).
- Logs: files older than 30 days removed, 20 MB per game and 150 MB total (oldest first; current launch/Steam logs and files written in the last 10 minutes are kept); 10 newest diagnostics reports.
- Moves update saved install records; existing stale records are reconciled by app name when exactly one library game matches; ghost app folders (no Info.plist, only Nokcandu-generated files, same-named game elsewhere) are moved to the Trash automatically. Settings writers no longer create folders for an app that has moved, and maintenance skips games being moved.

**Moves**
- Move… sheet: shows the app, the game's files and restore points with sizes and current drives; choose a destination for the app (Mac-formatted) and, separately, for the game's files (any drive, or inside the app). Copies use `ditto` through a hidden partial name, report progress, and are compared file-by-file (name, size, links) before the source is removed.
- Launchers (Steam, Battle.net, EA app, Ubisoft Connect) move whole with their games and leave a symbolic link at the library place so every shortcut, script and saved path keeps working. The library lists the link (the real app is skipped if its folder is also a library folder); a link whose drive is disconnected is shown as offline. Restore points and removal follow the real app.

**APFS games volume**
- Storage → Drives lists external drives with format/free space. On ExFAT/FAT drives, Create APFS Games Volume makes a growable APFS sparse bundle (`hdiutil create -type SPARSEBUNDLE -fs APFS`), opens it, adds it as a library folder (optionally the install folder) and registers it for automatic opening.
- Automatic opening: Nokcandu attaches registered images at launch and when any drive mounts; a launchd agent (`io.github.seastwood.nokcandu.gamesvolumes`, `StartOnMount`) does it while Nokcandu is closed. Existing images on a drive can be adopted (Use for Games). Eject closes the volumes on a drive before ejecting it.

## Verification
- Full suite: 360 tests (355 existing + 5 new `SpaceManagementTests`: string ownership incl. `/private` and linked apps, copy comparison, link-preserving move and return with single listing, install-record reconcile + ghost detection, log retention), 0 failures.
- On the reporting Mac: idle CPU before/after as above; startup burst (~10 s at ~100%) reduced to ~2 s at ~25% after caching launcher registries and game-folder program names; four previously moved games relinked in Applications and listed once; helper libraries updated in all apps on the APFS volume (including linked launchers); stale install records reconciled and the BF1942 ghost folder removed.
- Not yet exercised on real data at the time of writing: moving game files to/from ExFAT through the sheet, a full app round trip on real games, games-volume creation/adoption/eject, Free Up Space actions.

## Limits / follow-ups
- Copy progress is estimated by measuring the partial copy every 3 s.
- Engine files in apps moved to another APFS drive are full copies there (clones cannot cross drives). A per-volume engine cache that clones identical files would remove that duplication.
- A launcher on a games volume needs the volume open to start; Nokcandu shows it as offline otherwise.

## Follow-up: slow game switching (Nov 5)
After the first round, switching games was still slow. A 14 s `sample` while clicking between four games showed the main thread ~44% busy in view bodies doing disk work on every draw: `ComponentFixesView` (`CompatibilityFixes.unavailable` per component: program/folder inspection, Steam manifests), `GameWineSection` and `PendingSettingsSection` (reading the settings queue), `CinematicFix.likelyUsesDirectShow`, the engine notice and `PendingSettings.controlTitles`. These are now computed in `.task` off the main thread and cached in view state. The same measurement afterwards: main thread ~6% busy, no Nokcandu frame above 25 samples.

Because helper-activation checks now run on change rather than every 3 s, the check is re-requested after startup maintenance refreshes helper files and when Nokcandu becomes active (otherwise a stale "helper needs updating" note could stay for up to a minute).

## Follow-up: moved games vanished from Applications (Nov 5)
Moving a game's app to the APFS games volume removed it from ~/Applications, so Finder/Launchpad no longer showed it. Every app move now keeps a symbolic link at the app's place in the standard games folder (the same mechanism launchers use), registers the new location with Launch Services, and rewrites paths that named an earlier real location. Games moved by older versions get their link automatically during maintenance (verified: BF1942 Moongamers, OpenUA, Rage of Mages 2 and Warcraft III now appear in ~/Applications/Sikarugir as links and are listed once in Nokcandu). Moving an app back to the standard folder replaces the link with the app.

## Follow-up: linked apps must be handled by their real path (Nov 5)
With moved apps listed through their Applications link, helper updates silently skipped them: several writers refuse to write through links inside apps (a safety rule), so the "helper needs updating" note stayed. `GameLibrary.inspect` now resolves an app link to the real app, hosted games resolve their launcher path, and the shared Steam path resolves too; the link remains only the Applications entry. Scans de-duplicate by real path.

## Follow-up: startup burst (Nov 5)
A launch-time `sample` showed maintenance walking every launcher-installed game folder for program names (`RawMouse.exeNames`, also via microphone routing) and re-reading/splitting each launcher's `system.reg` for every game (`PCLaunchers.registeredGames`, `BattleNet.registeredGames`, offline-drive checks). Program names are now cached on disk by folder modification time (≤ 1 day) and registry-derived lists in memory by file size/mtime. Launcher upgrades skip the per-game process check when nothing would change.

## Real-library walkthrough (Nov 5)
Done through the app on the reporting Mac:
- Free Up Space: deleted orphaned restore points for Steam, Battle.net (both moved to the games volume), EA app (removed), BF1942 and Rage of Mages 2 (moved). Mac free space 14–15 GB → 33 GB. Fix found: points left at the standard folder for apps now reached through an Applications link were not reported (the link made the app look present); now they are.
- OpenUA files Elements (ExFAT) → inside its app on the games volume via the ExFAT-overhead suggestion (sheet now preselects "inside the app"): 660 MB that took 7.36 GB; Elements free +6.7 GB.
- Worms Armageddon round trip: app → games volume (link left in Applications, listed once), played; files → Elements, back inside the app; app → Mac, played. Fixes found:
  - Disc images can't be mounted at a folder on a disk-image volume (`hdiutil attach … Permission denied`, not a privacy prompt). MountedDisc folders of apps on a games volume are now links to a folder in Application Support (`Disc Mounts/<id>`), restored to real folders when the app returns; generated launchers resolve the link. Verified the disc mounted and the game ran from the volume.
  - `ditto` failed copying one RTF to ExFAT ("Invalid argument"); the copy now falls back to `cp -R -X` and is still verified file-by-file before anything is removed.
  - Moving an app back to the standard folder was refused as "already there" (the link resolved to the app); fixed and covered by the unit test.
  - Move destinations are radio buttons (all choices visible), and the sheet scrolls when taller than the window.
- "Use for Games" on the existing Seth Mac Games APFS image registered it and installed the `io.github.seastwood.nokcandu.gamesvolumes` agent (ran, exit 0).
- Created a test volume on Elements, confirmed it opened and was listed, then removed it with the new **Remove…** (only for volumes without games; image goes to the Trash).
- Not exercised: Eject (would disconnect the drive holding the user's games), Keep New Engine and Empty downloads (left for the user).

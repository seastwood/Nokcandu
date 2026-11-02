# External game launch and storage accounting — 2026-11-02

## Confirmed failure and repair

Battlefield 1942 stopped before Wine started after its game folder was moved to
Elements. Its launch log contained a shasum read failure, “Operation not permitted,”
for the original executable through the private prefix's game-folder symlink.
macOS TCC attributed the LaunchServices script-only app to `/bin/bash`, with
Perl/shasum as the accessing process. As a platform binary, bash could not prompt
for the game's removable-volume access. This was a file-access failure, not evidence
of broken game content, graphics or the community master-server correction.

A native universal app entry keeps the actual game app alive as the responsible
process while spawning its existing script with unchanged arguments. The user
received and approved the game's removable-drive prompt. Wine and D9VK then
initialized, and the user confirmed Battlefield opened. No privacy database edits,
Full Disk Access grant, root game launch, integrity-check bypass or game-file change
was required. The initial report that approval still did not open the game was
superseded moments later by the user's confirmation; the game was initializing.

## Shared implementation and migration

`LauncherEntry` applies to hash-verified generated custom launchers and recognized
original/Nokcandu-patched recipe launchers, independently of game name. Normal Play
ensures the native entry; fresh general installations and Steam shortcuts include
it. Saving an owned custom launcher also ensures it. `GameLibrary.inspect` retains
the script path for settings, hash checks, recipe matching and journals even though
CFBundleExecutable now names the native entry. Running games are not migrated.
Manual scripts, edited native helpers/plists and linked destinations are preserved.

A private recovery record contains the original/installed plist and the installed
helper fingerprint. Owned helper updates preserve the original Undo metadata and
roll back on an ordinary write/signing failure. `LauncherEntry.undo(game)` restores
the original app entry and removes only its matching owned helper/record; it refuses
changed metadata/helpers and running games. The shell script and game content are
not part of this migration. macOS may request game-specific access on first native
launch or after a helper identity update; approval remains a normal local OS action.

## No silent startup failure

The native entry records a local, atomic startup/exit receipt, including when a
script exits before a game log exists. Nokcandu watches actual Play attempts and
reports early failures with the exit status and a relevant bounded log detail.
File-access denials produce external-drive permission advice. Old receipts/logs
are ignored. Permission and store sign-in waits remain pending, with a visible
message after twelve seconds; the observer stays active until a window or failure
is observed, a newer attempt replaces it, or the user quits the game. Launchers
that hand off to a store are not treated as failures merely because their script
exits successfully. Native Mac apps are outside this Windows-launcher observer.
Wine virtual desktops and Battlefield's managed executable copies participate in
window matching. Observation does not kill, reset or change a game.

## What Move To leaves on the Mac

Elements is on the game-files-only path because its filesystem cannot host the
Wine prefix's symbolic links and Unix metadata. Move To relocated the actual game
folder and retained a link at its original Windows path. It intentionally leaves
the app, Wine runtime and private Windows setup locally; describing this simply
as a small app was misleading. Whole-app moves remain available to APFS or Mac OS
Extended destinations. No drive reformat or deletion of working runtime data was
performed or proposed as an automatic repair.

The old storage header counted only private APFS blocks while describing the result
as allocated size. That made Battlefield's local app look like about 17 MB even
though it contains approximately 1.94 GB of allocated blocks. Its separately stored
game files measured 4.82 GB on Elements. ROM2 similarly retains a local runtime.
Some runtime blocks are shared by APFS clones; adding per-app allocated sizes does
not measure unique disk consumption, and removing one clone may free much less.
macOS Storage's older larger entries are not proof that a second local game folder
survives the move.

Shared storage usage now reports allocated blocks without following external links.
Private-block sizing remains available for deletion/cache/restore-point savings.
Move capacity estimates also use allocated size rather than private clone blocks.
Move/install descriptions explicitly say that the runtime and Windows setup stay
local for game-files-only destinations. Changing these figures does not move or
delete content. Undo for actual relocation remains Move To back to the desired
folder; an allocation-only display correction needs no data migration.

## Verification

The original full suite passed 221 tests with seven optional skips before this
follow-up. Focused native-entry tests cover script/argument preservation, exit
status receipts, manual-change guards, Undo and cloned-runtime/link accounting.
Startup tests cover failure, stale receipts, pending authorization, store handoff,
window confirmation and managed executable names. The subsequent full suite passed
226 tests with seven optional skips; final packaging and UI verification are
recorded below when complete. Actual Battlefield normal launch is user-confirmed;
this is not a claim that every Windows game's own startup bugs can be prevented.


### Follow-up protection found by the end-to-end error test

The disposable startup test exposed an existing banner lifecycle defect: replacing
“Starting…” cancelled its auto-dismiss task, but `try?` swallowed cancellation and
still dismissed the newer error. Banner callbacks are now bound to their own ID,
cancelled tasks return, and errors stay visible until explicitly dismissed. This
fix applies to all Nokcandu error banners, not just game startup.

The same test caught an owned-helper upgrade problem: after CFBundleExecutable
points at the native entry, signing that file in place can make codesign validate
the surrounding bundle and reject its unsigned shell script. The replacement is
now signed separately in a temporary file, then installed only after rechecking
metadata, ownership fingerprint and link guards. Failed preparation leaves the
existing helper intact. The upgrade regression test preserves original Undo
metadata and verifies the installed entry can be upgraded. No broader signing or
macOS privacy protection is disabled.


### Installed UI verification

The final signed update is installed. A disposable private test app, using a fake
engine that deliberately exits 42, was launched with the normal Nokcandu Play
button. Its native receipt recorded exit 42 and the UI visibly reported that the
game could not start, including the controlled error line and Diagnostics guidance.
The newer error survived cancellation of the earlier Starting banner. The test
app uses no real game or game files and is removed after verification. Battlefield's
successful real launch remains user-confirmed; the update did not force-close it.

The new runtime/allocated figures and ExFAT explanation were also verified in the
installed UI. The storage overview now uses allocated size consistently with game
pages; private-block estimates remain reserved for cleanup/removal savings. The
fresh-tree full suite passed 226 tests with eleven optional skips, and a clean
ad-hoc app build and the signed local build completed. No game/runtime binaries,
machine-specific recovery data or raw diagnostic logs are committed.

# Storage settings: bounded lists and on-demand measurement — 2026-11-03

## Cause and scope

Storage previously called game sizing, all app-data sizing and orphan discovery on every appearance, waited for the combined result, then built every row inside a single eager vertical stack. Large libraries and long histories made the page lengthy. Game rows also evaluated move blockers, and the folders section queried availability/capacity while drawing the UI. The disk scans were already detached; simply moving the same combined load off the main thread would not resolve repeated work or eager row construction.

## Shared behavior

The Storage view now opens on Drives & folders. Games, Nokcandu data and Leftovers are separate sections with bounded, virtualized lists. Games includes search, displays names while the first measurement runs, and keeps completed estimates visible during refresh. Searches filter only Games, never silently filter another section. Folder metadata/capacity and cleanup operations run off the UI thread. Row drawing does not run process scans or disk move-eligibility checks; Move opens the folder chooser and the existing movement backend retains its safety checks.

The shared session-only `StorageInventory` caches completed Games/data/leftover estimates for five minutes and drive capacity for fifteen seconds. It coalesces concurrent readers, serializes walks within a section even across library changes, and ignores superseded completion writes. Current library metadata is part of Games/Leftovers cache keys. Refresh explicitly invalidates estimates, including any still-running walk, then obtains fresh results. Canceled view requests cannot publish into another selected section; their underlying walk can finish and be reused. Opening a different settings window does not force the same recent disk walk again. The measurement timestamp is visible; this is an estimate, not a live guarantee of freeable space.

Cleanup still requires an explicit action. Its actual operation runs in the background and invalidates cached measurements afterwards. Cached leftovers are rechecked against the current on-disk library before any are moved to Trash, and only reviewed rows still considered orphaned are included. No game, save, profile, explicit setting or manually edited launcher is migrated or deleted by opening Storage. Accounting definitions (allocated blocks versus private APFS blocks) are unchanged.

## Verification, migration and Undo

Tests cover scan sharing/reuse, expiry, independent section results, refresh during an unfinished walk, and the existing split-drive accounting regression. The full suite passed 264 tests with ten optional skips and zero failures before final UI and scan refinements; focused checks and production compilation cover the final scan path. Installation/UI evidence is added after checking the built app.

This is automatic UI/session behavior for new and existing libraries. There is no persisted cache or migration to Undo. Restart Nokcandu to discard estimates, or use Refresh to remeasure immediately. Returning to the prior app build restores the previous Storage layout; game data and saved settings are unaffected. First-time sizing of a large Games/data section still depends on its files and drive speed; the page stays usable while that walk finishes.


The built app was opened before replacing the installed app. The drive overview was complete at the first UI capture; Games measured successfully and search reduced it to the three Battlefield entries. Switching to Nokcandu data showed all five categories despite the saved game search. Returning to Games retained its earlier measurement timestamp instead of rescanning. The actual long orphan list remained contained in its own virtualized scrolling pane. No Empty, Clear Logs, Remove Unused or Trash action was invoked. The low-space drive warning tint is preserved. These are direct UI observations, not a broad hardware-independent timing benchmark.

The signed update was subsequently installed with a verified rollback copy. Opening Settings in the installed app immediately showed the compact drive/folder overview, with the existing library and storage locations intact. Installation did not move games or perform cleanup.

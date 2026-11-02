# Nonblocking game installation — 2026-11-01

## Cause and scope

The shared Add a Game flow presented `InstallerView` as a modal sheet on the
library. It prevented selecting or playing an unrelated installed game, including
ROM2 while Battlefront II setup ran. `InstallerView` also owned `InstallerModel`
with `StateObject`, and disabled Close during work. Merely enabling Close would
leave the task's lifetime tied to its presentation and lose the visible session.
This affects general game, store and launcher installation entry points.

## Change

Present a single **Game Installation** window using the same shared request flag
from the library, menus, welcome, profiles, stores and Steam setup. `AppModel`
owns `InstallerModel`; the window observes it. Closing the window returns to the
library without cancellation or resetting unfinished work. A directly observed
**Installation: game…** library shortcut reopens the current session. The footer
uses **Back to Library** during unfinished installation and remains enabled while
work runs. Explicit Cancel and Remove keep their existing meanings/protections.
Only completion or explicit removal clears the retained session. No second executor
is created when reopening the window, and normal saved-install recovery still
handles a full application restart. This change does not promise simultaneous
multiple installation executors; it allows other library actions during setup.

## Preservation and migration

No install-state format, game content, saves, runtime configuration or launchers
change for this UI fix. Existing saved installs resume into the new window.
The currently open Battlefront setup is a separate Windows process: shared
`CustomInstall.Acquire.runInstaller` uses `wine start`, records `acquire.opened`,
and returns to a handoff. The old progress panel's enabled Close returned to the
library while both existing Windows setup PIDs remained alive. No Continue,
Run Installer Again, removal, or game selection was performed on that installation.

Reverting the UI source restores the old modal presentation; existing state files
remain readable. Closing the new progress window is not Undo or cancellation.

## Verification

Development build passed. Live window/session verification is recorded below once
completed. Worker cancellation, remote multiplayer and Battlefront game installation
success are separate from this presentation change.


### Verified window/session behavior

The built app showed Game Installation as a standard independent window, not a
sheet. With a disposable session open, switching to the library and selecting
Battlefield 1942 succeeded and its Play/settings controls remained available.
The Installation shortcut returned to the same session. Back to Library closed
the window; reopening retained the same stage without re-creating the executor.
Removing only that disposable session reset the chooser successfully, with no game
files ever installed for the fixture.

A temporary harness compiled the exact current InstallerModel class and exercised
a suspended automatic worker: the same close cleanup retained executor identity,
running state and log; the task finished after release and only then could completed
session cleanup reset it. No mirror implementation was used. The combined full
suite passed 211 tests (9 skipped) with zero failures; signed app build passed.

During validation, the real Battlefront relocation finished normally and launcher
self-check passed. Its game process was subsequently visible as Running; the agent
did not launch it or confirm gameplay. Old Nokcandu was quit only after automatic
installation work finished. No installer/copy/game process was killed for the UI fix.


The final signed combined 0.12.2 app was installed in the normal Applications
location, and its signature/version were checked. Reopening that installed app
confirmed Add a Game creates a standard Game Installation window; Close returned
to the library. Battlefront remained Running across the handoff. The disposable
session was removed through its own Remove action; no test game files were created.

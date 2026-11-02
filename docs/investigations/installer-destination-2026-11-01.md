# Installer destination mismatch — 2026-11-01

## Confirmed cause

The user selected Elements for Battlefront II (2005). `CustomInstall.PrepareFiles`
prepared a linked `C:\Games\Battlefront II (2005)` folder, but the interactive GOG
installer defaulted to `C:\GOG Games\Star Wars - Battlefront 2`. The acquisition
handoff passed only the setup path, so the prepared folder went unused. The shared
StoreFiles fallback correctly copied 9.22 GB onto Elements, verified completion,
removed the old copy and left the original Windows path linked to the new location.
It was an avoidable second transfer, not a requirement of Wine or ExFAT.

## Shared correction

`InstallerDestination` recognizes valid Windows executables with the Inno Setup
loader data signature in a bounded first-4-MiB read. The reported GOG installer
has that signature at offset 70156. Do not infer installer format from a GOG-like
filename. [Inno's official command-line documentation](https://jrsoftware.org/ishelp/topic_setupcmdline.htm)
defines `/DIR=` as overriding the default destination displayed in setup.

For a private game whose prepared link still resolves to the selected external
folder, pass its Windows directory as a single `/DIR=` argument to `wine start
/unix`. The wizard remains interactive and the player can review/change the
location. No silent mode, agreement acceptance or forced installer clicks are
introduced. General Windows-installer flows benefit regardless of game name.
Unknown installers/MSIs keep their arguments unchanged; the acquisition UI displays
the intended Windows folder and explains that choosing another folder may require
an extra move. Internal-install defaults and launcher-specific workflows are preserved.
The existing safe relocation remains necessary when setup overrides/ignores the
suggestion or its format is unsupported.

## Existing installations, preservation and Undo

Do not restart an already opened installer or interrupt an existing copy. Saved
acquisition handoffs continue their existing checks; automatic routing applies only
when a future installer is launched with a verified prepared destination. No existing
folders, installed programs, saves, preferences or profile schema are rewritten by
this change. The current Battlefront transfer completed and its launcher self-check
passed; gameplay was not marked confirmed by the agent. Reverting the handoff code
restores the old behavior for future launches; completed installs need no migration
or Undo. Shared profiles use the updated acquisition infrastructure automatically;
no machine-specific destination is added as a portable fix ID.

## Verification

Two regression tests cover format recognition, malformed/non-PE/MSI exclusion,
external preparation, a directory with spaces, preservation of internal/launcher
setup defaults, and StoreFiles skipping relocation when game files already landed
on the prepared external folder. A failed first comparison used directory URLs
with inconsistent trailing-slash metadata; normalized canonical path comparisons
fixed it. The reported GOG installer was inspected read-only, not reinstalled.

An isolated Windows argument recorder received exactly one `/DIR=` argument through
the same `wine start /unix` path, including spaces and normal Windows separators.
This verifies argument transport; another full GOG install was not performed.
The combined full suite passed **211 tests, 9 skipped, zero failures**.

# Automatically add installed store games — 2026-11-03

## Problem and scope

Steam, Battle.net, EA app and Ubisoft Connect already exposed local installed-game readers and explicit Add to Nokcandu actions. Discovery was tied to individual store/detail views, and finishing a download inside an external client did not create a game-list entry automatically. Nokcandu's own installer refreshed the library when its window disappeared, but a retained window could leave the sidebar stale.

This change reuses those local readers; it adds no account API calls, purchases, downloads or game installation automation. Nokcandu's integrated GOG/Epic/Amazon acquisition still uses its existing installer/native completion paths. Optional external Galaxy/Epic/Amazon launcher clients still lack registered-game readers; this change does not claim to discover arbitrary installs inside those unsupported clients.

## Shared implementation

`StoreGameDiscovery` checks installed Steam manifests and existing Battle.net/EA/Ubisoft registration readers. Steam must report fully installed with no download activity and have a present content folder; known runtime/redistributable IDs are excluded. Other clients require a present registered installation folder; EA additionally requires its directly launched executable to exist. Offline, missing and unknown folders do not produce new shortcuts. Battle.net/Ubisoft registry completion is the existing readiness signal, not a proof of gameplay compatibility.

`AppModel` requests discovery at startup/library refresh/mount events and at most every 15 seconds during its normal timer. One request runs at a time; filesystem reading, executable inspection and icon/shortcut generation run off the UI thread. New additions refresh the sidebar and storage cache without changing selection. The check works with Game Stores closed while Nokcandu remains open. On the next launch it catches installations completed while Nokcandu was closed. There is no always-running system service.

The common creators now serialize manual and automatic additions, recheck the current library and reuse a matching app. Identity is Steam app ID or client/product plus the private host's stable custom ID, preserving distinct installations in different hosts and surviving a host move. Names are not identities. Existing settings, renamed apps and manually edited scripts are not rewritten by discovery. A failed creation rolls back only its newly allocated shortcut; other candidates continue and errors are visible without repeating identical banners every poll. Automatic addition never modifies a running host or installs optional compatibility components.

Nokcandu's retained installer calls back to the library once the launcher self-check passes or the installation completes, including integrated Windows store downloads. Existing native-store completion already refreshes the library. Steam's install message now explains automatic addition instead of asking for another manual step.

## Existing installations, removal and Undo

The first check adopts existing shortcuts by identity and adds any eligible missing entries. Local discovery metadata remembers app locations so disconnected shortcut drives do not create duplicates. If any configured app-library volume is offline, unknown new additions wait until it can be checked safely. Manual Add remains available.

A removed shortcut must stay removed even if its game files remain installed in the client. Nokcandu records exclusion before its recoverable Trash operation and restores the policy if removal fails. A previously remembered app deleted in Finder is also excluded once its parent library is known to be present. A corrupt discovery record fails closed and reports the problem. Manual Add or restoring a shortcut clears its exclusion when seen again. Removing and restoring apps remains recoverable using the existing Trash flow; no game or save data is deleted by discovery. Rolling back the Nokcandu app stops the new polling, and already added shortcuts remain ordinary managed game apps.

The metadata is local library organization, not a transferable compatibility profile. It contains no credentials and is not exported in game profiles. Existing creation paths continue to apply normal game settings and profile behavior.

## Validation and limitations

Ten isolated regressions cover EA/Ubisoft readiness and offline paths, Steam download/runtime exclusion, actual shortcut creation and repeated/manual addition, settings/script preservation, successful/failed removals, corrupt policy, per-candidate failures, concurrent scans, disconnected shortcut/library protection, Battle.net discovery/creation and host identity, and Finder removal. All fixture writes and created apps stay under temporary test directories. An initial URL equality assertion exposed macOS `/var` versus `/private/var` aliases; canonical path comparison verifies the actual same shortcut.

No new paid/downloaded game is required to exercise the creation path. The full suite passed: 287 tests, 10 optional skips, zero failures. After the final exclusive app-directory reservation safeguard, all 22 relevant discovery/launcher/removal tests passed again. The production build and deep signature verification passed. In the real library, the preview automatically found and added an already installed Dead by Daylight Steam game while Game Stores was closed; the sidebar showed its new entry and retained the current selection. Ten existing store entries were adopted without duplicates, with eleven total remembered entries after addition. Existing normal startup maintenance also refreshed signed helper copies and managed metadata; isolated tests verify discovery itself preserves custom settings and manual launcher edits. The update was installed with the previous app retained for rollback. No store account login, new download, game launch or gameplay test was required for this library behavior. Longer-term external client timing remains dependent on when each client flushes its local manifest/registry record; the 15-second interval starts after that record is visible.

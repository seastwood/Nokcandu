# Fullscreen Space input recovery — 2026-11-03 to 2026-11-04 (deferred)

## Current status — deferred at the user’s request

On November 4 the user reported that BF2 works better with the resizable virtual screen disabled and questioned continuing this isolated issue. Investigation was deferred. Both saved/applied settings are Off. BF2’s actual engine has the normal driver, with neither diagnostic strings nor the candidate selector. No shared focus fix was installed into the user’s Nokcandu app or published.

The failed candidate patches/native harness were removed from active source paths and kept only as temporary local investigation artifacts. Wine 10/11 source trees, driver outputs, the built app and corresponding-source archive were regenerated from the unchanged production patch series. Checks confirm the candidate/trace markers and source files are absent. Existing user game settings, content, saves and manual launchers were left intact. The exact earlier driver recovery copy remains local; no runtime binaries or raw diagnostic logs are committed.

## Report and scope

BF2 accepts keyboard/mouse initially in fullscreen. After swiping to another macOS Space and returning, input stops; windowed operation remains usable. The user later reported the running game appeared frozen while attempting reproduction. Do not equate that with a confirmed focus-only failure or a renderer deadlock.

## Inspection and comparisons

Wine 10/11 application deactivation invalidates outstanding focus offers and posts APP_DEACTIVATED, which can send Windows foreground to the desktop. The current Space-change handler updates display capture/window levels but does not explicitly re-offer Windows focus. Application activation updates display state but likewise does not re-offer it when Cocoa keeps the same key window. This is a plausible cause, not yet measured in the reported broken BF2 state.

A first LLDB inspection failed because NSApp's debug type conflicted with the expression declaration. It yielded no valid focus observation. The old process was later defunct and BF2 was relaunched; do not repeat a slow invasive debugger expression on a user game to establish this theory. A subsequent short sample of the new process showed the Cocoa main thread servicing its normal event loop, not a demonstrated Cocoa lock deadlock; Windows game-thread health and rendering were not established by that sample.

An isolated Windows DirectInput probe initialized successfully in a separate prefix, reporting acquired keyboard and foreground status. Computer-use could not bind its shell-parent app reliably, and no Space-return baseline was obtained. Its own prefix was stopped without terminating the real game. No keyboard values, account data or packet contents were recorded.

## Candidate, tests and pending verification

Both version-specific driver patches add deferred/coalesced focus recovery on Space change and app activation. It uses only Cocoa's existing key window and requires the app to be active, a WineWindow in native Mac fullscreen, visible, non-minimized, on the active Space and eligible for Windows foreground. It never activates a background app, selects another Space/window or changes ordinary windowed input. It posts Wine's existing focus-offer event rather than synthesizing keyboard or mouse events.

Wine 10 and 11 candidates build. `Engine/winemac/tests/space-focus.py` compiles the actual patched method against deterministic native state objects and checks coalescing, settled activation/current-key selection and eight exclusion states. Both pass. Five existing Swift driver/version/migration tests pass. This validates guards and packaging compatibility, not actual game recovery.

Before the controlled staging described below, the candidate was not installed into BF2 or the user's Nokcandu app. The user was asked to close the stalled BF2 session before a controlled private-session restart and candidate test. Preserve BF2Hub/game settings, content, saves, microphone choices and manually edited launchers. Keep a copy of the currently working driver/stamp before staging; restore those if the comparison fails. Do not publish or mark this fix confirmed until BF2 Space-away/back input and normal windowed behavior are verified.

## Expected migration, if confirmed

Use the shared version-matched Wine driver packaging and existing source/installed stamps. Games already using Nokcandu's driver can receive the new bytes on their next closed Windows-environment start, with original-engine backups retained. Do not claim the correction reaches stock-driver sessions where Nokcandu's driver is not installed. Unsupported Wine versions, input permissions and explicit game settings remain unchanged. Final evidence, migration/Undo details and any superseded theory must be added after the controlled game comparison.

## Controlled BF2 staging

After the user confirmed BF2 was closed, only its private Wine server/session was stopped (including idle BF2Hub). Current driver files and their ownership stamp were copied into a separate local recovery directory with before/candidate hashes. The candidate's three version-matched driver files were staged atomically and the Unix module re-signed; the original-engine driver backup was left intact. The ownership stamp was updated to the candidate source/installed hashes. Game settings, scripts, content, saves and microphone policy were not changed. BF2Hub was reopened through the normal app icon and candidate hashes were rechecked afterwards. The user was asked to test initial input, repeated native fullscreen Space-away/back cycles and windowed input. Result remains pending.

## First candidate failed the game comparison

The user confirmed initial input, then loss after Space-away/back with the candidate loaded. Shrinking the window, minimizing and restoring brought controls back. Do not ship the first deferred key-window re-offer as a confirmed correction. Its native guard tests passed but did not reproduce the missing real event/state transition. The exact installed driver backup is retained for rollback.

A temporary driver is being built from the working source tree to log only application activation, key/window state flags, focus-offer events and backend focus/deactivation event names. It logs no keyboard values, mouse contents, titles, account/session fields or network traffic. Trace source is temporary and must not enter the final patch or published source archive. The user was asked to close BF2 before staging this diagnostic comparison.

## Diagnostic comparison and deferral limits

The user repeated the same behavior with the state-only diagnostic driver and restarted the game during the comparison. That did not establish a new root cause. Traces captured initial activation/fullscreen entry, but a complete correlated broken-return/restoration sequence was not retained after the restart. Do not reinterpret the guard tests or initial focus offers as a successful fix. If this is resumed for BF2 or a second affected game, capture the full native and Windows focus event order before proposing another shared recovery change. The minimize/restore workaround remains a user observation, not a system-wide repair.

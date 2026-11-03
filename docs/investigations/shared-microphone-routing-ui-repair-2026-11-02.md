# Shared microphone identity, UI polling and helper repair (2026-11-02)

## Report and evidence

The user reported a beachball on every Nokcandu click and silent CS2 microphone input despite choosing Allow. Read-only inspection found CS2's saved microphone choice On, its explicit `cs2.exe` and Steam app-ID routes allowed, the shared prefix default blocked, and a loaded older helper matching the installed app. The development live-switch build had not been installed. The microphone tray icon alone did not establish delivered samples.

A three-second sample of the frozen app showed almost all main-thread samples inside `AppModel.refreshRunStates → GameLauncher.runState → processSnapshot → Shell.run(ps)` sleeping/waiting. The repeating three-second timer could initiate expensive process/LaunchServices work on the main actor. A standalone Foundation scan sometimes took over five seconds and hit its old timeout, whereas direct subprocess scans completed quickly. That timing difference is observed; its lower-level cause is unresolved.

Wine 11's `dlls/ntdll/unix/env.c:rebuild_argv` removes the loader argument and may move the argument strings themselves. The old microphone guard read `_NSGetArgv()[1]` on every policy lookup, after that rewrite. In a shared prefix this can lose the executable route and use the blocked shared default, even though the UI preference is On. Private-prefix capture tests had a permissive prefix default and therefore did not exercise this failure. Constructor-time renderer routing already happened early; microphone checks needed their own stable identity.

## Shared corrections

- Snapshot the Windows program **bytes** in an early helper constructor. Do not retain a pointer into mutable argv. Read policy choices dynamically, so the saved switch remains live. Accept both loader+program and already-shifted Windows-program argv layouts. Unknown identities retain the safe prefix default.
- Batch library status checks around one process snapshot; share it with Steam matching. Perform process, LaunchServices and hot-corner checks off the main actor, coalesce timer requests and discard/retry results for an obsolete library revision. Move privacy/launcher maintenance off the UI path too. Microphone-setting writes run off the UI actor and refresh only the affected library item.
- Repair now verifies/restores the current bundled audio/input library **before** shared Steam/Battle.net shortcut early returns, resolves the owning host, refreshes that prefix's saved per-program microphone policies and prepares its existing privacy metadata. A linked helper path is preserved and reported as failed. Owned helper replacement is atomic and hash-verified; normal helper maintenance and the raw-mouse switch use the same installation method.
- Repair preserves manually edited custom launchers instead of forcing a generated script over them. Settings JSON, game content, saves and unrelated games' microphone choices are preserved.

## Verification and limits

Hardware-free tests mutate the original Wine-style argv pointers and program bytes after constructor initialization and assert the saved identity stays intact. Existing routing/capture tests continue to cover blocked input, output forwarding and live stop/resume. Repair tests cover missing, stale and corrupt helpers, idempotence, linked-file preservation, unchanged settings/manual scripts and selecting the owning shared host instead of a shortcut's helper directory. Process-state, Steam matching and subprocess-output tests cover the status dependencies.

CS2 voice input itself must be checked after the corrected helper is installed and Steam/CS2 reopen; do not equate the policy regression test, OS tray icon or successful setup with audible game voice verification. No TCC database edits, system audio-device changes or global Steam microphone opt-in are part of this fix.

## Fresh installation, migration and Undo

All applicable Wine games get the same corrected helper. Existing applications receive it through normal shared helper maintenance or Repair. Replacing a dylib on disk cannot change code already mapped into a process: close/reopen affected Windows programs, including their shared client, to activate it. Repair states this requirement explicitly. Profiles retain the existing per-game microphone preference; they do not carry OS consent or machine-specific helper binaries.

Turn the microphone switch back to restore its previous choice. Revert the application/helper code and reopen the affected client to undo the infrastructure change; helper binaries are generated from the app rather than stored in settings journals. Existing OS Allow/Deny decisions are untouched. A rollback copy of the previously installed Nokcandu app is retained locally when installing the update, outside the repository.

## Installed verification

The complete suite passed 248 tests with ten optional skips and zero failures. The signed build passed deep/strict signature verification and was installed atomically with a local rollback copy retained. The restarted app could select CS2, open settings and run Repair. Its visible report confirmed “Audio and input helper: Matches this Nokcandu build; saved per-game microphone policies refreshed.” A read-only hash comparison confirmed Steam's helper matched the installed build. The asynchronous microphone switch changed from Off to On without a restart dialog or UI freeze; Steam's separate opt-in remained Off. CS2 was then launched for the user to verify actual voice input. The Mac's default External Microphone was present and matched CS2's saved device override. No global audio settings or OS permission grants were changed.

A post-install two-second app sample showed the main thread servicing the normal AppKit event loop rather than sleeping in the process scan. CS2 reached its new Windows process after Steam started; actual voice confirmation was requested from the user and remains pending.

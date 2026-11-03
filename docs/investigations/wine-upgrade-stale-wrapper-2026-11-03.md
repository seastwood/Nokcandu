# Wine 10 → 11 upgrade with a stale game identity wrapper — 2026-11-03

## Confirmed failure

While preparing 0.12.3, the user selected Wine 11 for Falconeer (previously Wine 10.0 r8). The saved request reported wineboot/cmd exit 1 and an ntdll.so path containing an extra lib/wine segment. The target engine itself had passed its cache self-test. Inspection confirmed the original game was restored to Wine 10, with its ntdll.so present, and the requested Wine 11 choice remained pending. No public release tag had been pushed; the outdated test-package run was canceled.

A disposable Falconeer clone reproduced the same ntdll failure before the correction. Its old GameApp identity wrapper held Wine 10's loader. The Wine 11 exec interposer could redirect the new engine into that stale wrapper without checking the recorded engine stamp. Setup arguments `wineboot` and `cmd` also lacked `.exe`, so the background-utility classifier failed to recognize them. This is a shared engine/helper transition bug, not a missing game file or a reason to reject the cached Wine 11 engine globally.

## Shared correction

Engine replacement's wineboot and Windows-command check use `NOKCANDU_NO_GAME_APP=1`, so they run the newly installed engine directly while retaining the normal microphone guard and Wine environment. This flag is local to setup; ordinary game launches still use their identity wrappers.

The Wine 11 helper now checks the GameApp engine stamp before redirecting an exec, matching the protection already present on the older wrapper path. A stale, missing or unrecorded wrapper falls back to the real engine loader. Background utilities are recognized with and without the `.exe` suffix, including full Windows paths; similarly named games are not classified as system tools. Normal launch refreshes generated game wrappers for the selected engine.

This applies to all supported managed Wine environments, not only Falconeer. Fresh installations keep their normal generation path. Existing apps receive the shared helper through normal generation/migration/Repair; the upgrade preflight flag also works with their older helper because that helper already supports the flag. The saved failed request can be retried without choosing its version again. Engine and prefix backup/rollback remain available; discarding an unapplied request leaves the original engine unchanged. No game content, saves or manually edited launcher is replaced by this correction.

## Evidence and superseded coverage

The pre-fix clone test reproduced wineboot 1/cmd 1 and the same duplicated ntdll path. With corrected setup environment, Wine 10 → 11 succeeded and rollback restored the original Wine loader and system.reg hashes. The earlier explicit-version and deferred-settings real-Wine tests exercised a historical Wine 10 target; they did not establish this upgrade direction with an existing Wine 10 identity wrapper. Their earlier results remain valid for the tested direction, but were insufficient to declare both directions verified.

C regression checks cover bare/suffixed utility names, similar foreground game names and current/changed/missing wrapper engine stamps. A Swift check verifies setup bypasses identity redirection while retaining microphone-off policy; normal launch environment is unchanged. Verification completed: the full suite passed (329 tests, 14 optional skips). The production-helper clone test also passed: it upgraded to Wine 11, ran an ordinary Windows command while deliberately retaining the stale Wine 10 wrapper, and rolled back to exact original loader/registry hashes. The corrected 0.12.3 DMG passed checksum, deep strict signature, helper-version and bundled-module checks. Installation used the managed app backup/replacement path. Retrying the actual Falconeer pending request completed successfully; the installed UI shows Wine 11.0 r1, no pending error, and Keep/Roll Back to Wine 10.0 r8. Gameplay on this newly selected engine remains a separate user trial; startup-tool and upgrade behavior are verified. Final public release evidence belongs in the release investigation.

# Apply pending settings when the environment closes — 2026-11-04

## Report and confirmed gap

The BF2 screenshot showed saved Audio Buffer, DirectX 8 compatibility, DirectX 9 extras and Graphics changes while Play was available. The queue was previously drained on setting save or game launch, but the regular session-status refresh did not drain it after exit. The game did not need to reopen to make those settings safe to apply.

## Shared implementation

Nokcandu's regular status refresh now schedules an independent background pending-settings monitor. It uses the existing durable queue, ownership checks and cross-process apply lock. All queue-supported settings and compatibility operations use the same path, for both private games and shared store environments. Private resizable-window choices also reconcile when idle. Shared store environments retain their per-game virtual-screen choices; the monitor does not select an arbitrary game's window preference for other games.

A reliable closed session can apply immediately. Only idle Wine services may be stopped; games, store clients, installers and unidentified programs remain active and postpone changes. Unknown process status also postpones changes. Activity is checked again before each queued operation, so opening a game during an earlier operation leaves subsequent requests queued. This is a safety check, not a new exclusive lock against all external Wine launches.

Concurrent monitor polls coalesce. Shared hosts are processed once per poll. Failures retain requests and are reported once per request set rather than retried every three seconds; a new request, a subsequent active-to-idle session, or Try Applying Now permits another attempt. Applying changes never requests a game launch. Some compatibility operations can download packages or invoke their existing setup utilities.

## Interface

The summary is now Pending Changes, with wording explaining automatic application after all programs in the environment close. Pending badges sit beside affected controls. Performance badges compare the queued values against persisted values, not the desired-value preview, so only changed toggles are marked. Wine/performance/audio settings are host-wide; other badges follow their game identity. Live microphone settings are excluded. Live virtual-resolution changes are not falsely marked as pending on/off changes.

## Fresh installs, migration and Undo

No queue-format migration is needed: existing saved requests drain through the same executor when Nokcandu observes an idle environment. The monitor runs while Nokcandu is open. Existing app-icon preflight remains available when Nokcandu is closed. Discard Pending Changes removes queued requests without changing the currently applied settings; after application, use the setting's existing reversal or compatibility Undo. Game files, saves and manual-launcher protection remain under the existing executor's ownership rules.

## Verification

- Full suite before the final overlapping-poll regression: 341 tests, 15 optional skips, zero failures.
- Focused pending-settings suite including that additional regression: 24 tests, zero failures.
- New tests cover stopped-game application without launching, exact toggle markers clearing after application, active/unknown deferral followed by application, failure retention and bounded retries, corrupt requests, overlapping polls, and a game reopening during a batch.
- BF2's actual private environment was confirmed closed during read-only verification. Its older screenshot requests were already absent by the time of this check; no replacement requests were fabricated in the user's game.

The required Wine/IPX production package built successfully and was installed through app-only rollback recovery. Strict/deep code-signature verification passed. Nokcandu reopened with BF2 Ready, its existing graphics/audio/component settings present and no stale pending summary. The live game was not launched or its preferences changed for this UI check. Control-marker mapping for the exact four screenshot requests was verified in the isolated regression fixture.

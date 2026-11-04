# Release 0.12.4 verification — 2026-11-04

## Authorization and scope

The user requested a new release once verification passes, prioritizing complete profile application. This release collects changes since 0.12.3: complete component profiles, shared-launcher component isolation, catalog parity, pending settings on environment exit, independent icon editing and installer-label cleanup. User-facing scope and unresolved microphone/fullscreen issues are disclosed in release-notes/v0.12.4.md.

## Verification

Implementation commit b33b860 passed 355 local tests with 16 optional skips; required Wine driver/native-IPX production packaging and the real five-component shared profile integration passed. The signed app was installed and launcher-game controls were inspected without enabling components on real game content. Synthetic parent/child DLL isolation passed under Wine 10/11 in both architectures. Companion catalog commit 8f576f2 passed its tests and GitHub validation. Full [app CI 41899186139](https://github.com/seastwood/Nokcandu/actions/runs/41899186139) passed on b33b860: 355 tests with 22 expected clean-runner skips, app build, all 16 socket checks and four client/child routing combinations across Wine 10/11 and both architectures, and shell checks. The revised engine watch also passed. Release changes beyond that implementation commit are version metadata and documentation; the tag workflow reruns tests and requires both custom driver and native-IPX packaging. The local 0.12.4 DMG mounted read-only; its app reported 0.12.4 and passed deep/strict signature verification. DMG and native-IPX source checksum files both verified. Final public release-package results are recorded below after completion.

## Migration and Undo

The shared component generation, exact-program routes and normal maintenance/Repair paths cover new and existing recognized installations. Updates do not automatically enable optional game components. Changed files/manual launchers are protected; games and saves remain in place. Profiles retain supported component choices. Each component has Undo; app rollback retains existing game data and engine selections. Schema 3 prevents older apps from applying scoped shared-launcher profiles with old global-client behavior.

## Limits

The microphone-Off permission prompt and BF2 fullscreen Spaces issue remain open. The release includes no experimental focus driver or temporary launcher-identity comparison. Shared networking/provider and launch-wrapper restrictions remain component-specific; fixture success does not prove every store build or game. No credentials, game/runtime binaries, account traces or machine-specific backups are committed.

# Release 0.12.4 verification — 2026-11-04

## Authorization and scope

The user requested a new release once verification passes, prioritizing complete profile application. This release collects changes since 0.12.3: complete component profiles, shared-launcher component isolation, catalog parity, pending settings on environment exit, independent icon editing and installer-label cleanup. User-facing scope and unresolved microphone/fullscreen issues are disclosed in release-notes/v0.12.4.md.

## Verification

Implementation commit b33b860 passed 355 local tests with 16 optional skips; required Wine driver/native-IPX production packaging and the real five-component shared profile integration passed. The signed app was installed and launcher-game controls were inspected without enabling components on real game content. Synthetic parent/child DLL isolation passed under Wine 10/11 in both architectures. Companion catalog commit 8f576f2 passed its tests and GitHub validation. Full [app CI 41899186139](https://github.com/seastwood/Nokcandu/actions/runs/41899186139) passed on b33b860: 355 tests with 22 expected clean-runner skips, app build, all 16 socket checks and four client/child routing combinations across Wine 10/11 and both architectures, and shell checks. The revised engine watch also passed. Release changes beyond that implementation commit are version metadata and documentation; the tag workflow reruns tests and requires both custom driver and native-IPX packaging. The local 0.12.4 DMG mounted read-only; its app reported 0.12.4 and passed deep/strict signature verification. DMG and native-IPX source checksum files both verified. Final public release-package results are recorded below after completion.

## Migration and Undo

The shared component generation, exact-program routes and normal maintenance/Repair paths cover new and existing recognized installations. Updates do not automatically enable optional game components. Changed files/manual launchers are protected; games and saves remain in place. Profiles retain supported component choices. Each component has Undo; app rollback retains existing game data and engine selections. Schema 3 prevents older apps from applying scoped shared-launcher profiles with old global-client behavior.

## Limits

The microphone-Off permission prompt and BF2 fullscreen Spaces issue remain open. The release includes no experimental focus driver or temporary launcher-identity comparison. Shared networking/provider and launch-wrapper restrictions remain component-specific; fixture success does not prove every store build or game. No credentials, game/runtime binaries, account traces or machine-specific backups are committed.


## Published package verification

Tag `v0.12.4` resolves to `f9539499137b87a313bda4b1a979f585d0b23931`. [Release workflow 41902533400](https://github.com/seastwood/Nokcandu/actions/runs/41902533400) succeeded, including both Wine driver checks, native-IPX building/patch checks, 355 tests with 21 expected release-runner skips and no failures, and DMG packaging. [Nokcandu 0.12.4](https://github.com/seastwood/Nokcandu/releases/tag/v0.12.4) was published as a regular non-draft release on 2026-11-04 at 20:17:36 UTC with four assets.

The actual public downloads matched all GitHub asset digests and both published checksum files:

- DMG SHA-256: `94921bb8cbcd942f9adbf50925b14b54554162c20f1c1709259070910c0bce3c`.
- Native-IPX corresponding-source SHA-256: `8407b90acbb78e0cb41e9e4b767044c721cdbf0af88cbfaedb9dfb9862b63f84`.

The public DMG mounted read-only; its app reported 0.12.4 and passed deep/strict signature verification. Both Wine versions contain all three driver components; the native-IPX SHA256SUMS verified; launcher/audio helpers are present and the helper-build stamp matches the tested local build. The source archive contains pinned Wine 11 source, packet-module patches/build scripts and license notices. The Mac was locked during the final optional install check, so the public package was not substituted for the already-installed tested b33b860 build. It is available through the ordinary updater. No game files or settings were changed during public-package verification.

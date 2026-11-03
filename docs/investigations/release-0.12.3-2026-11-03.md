# Release 0.12.3 verification — 2026-11-03

## Scope

This release collects the shared game compatibility, networking, audio/privacy, settings, installation, storage and app-recovery changes since 0.12.2. User-facing changes and limits are in release-notes/v0.12.3.md; confirmed implementation evidence remains in the component investigations linked from the documentation index.

## Evidence before packaging

The latest implementation commit passed GitHub CI: unit/regression tests, app build, actual Wine 10 and 11 socket-event checks in 32-bit and 64-bit execution, and shell checks. Local production builds/signature checks and installed UI checks passed for the settings and rollback features. Local rollback validation included signed disposable app bundles, preservation of user data, blocked replacement of active processes, stale/corrupt plans and standalone recovery of missing/damaged apps. The user's working installation was upgraded with a verified recovery copy; it was not downgraded as a test.

The release version and notes are being prepared separately from implementation changes. A workflow-dispatch package was attempted first, then canceled when the upgrade regression was reported; the corrected local package and CI checks passed before the public tag was pushed. The release workflow requires the supported Wine Mac drivers and native IPX packet module and includes its corresponding source archive and checksums. Final package/run evidence is recorded after verification.

## Migration and Undo

Existing game content, saves and explicit user settings stay in place. Recognized generated launchers/helpers migrate through shared generation and Repair paths, preserving manual modifications. App-only rollback preserves user data and engine selections. Managed app replacements keep a prior signed app plus an independent recovery command under Application Support/App Versions. Historical apps may not understand new settings and do not gain this release's updater behavior automatically. Native IPX permission and machine-specific adapter data remain local.

## Limits

Synthetic and real-Wine CI checks do not establish compatibility with every game, device, router or anti-cheat configuration. Detailed game-specific menu/gameplay confirmations and unresolved limits are recorded in the relevant investigations. No credentials, raw account/session traces, machine-specific backups or runtime binaries belong in this release commit.

## Pre-publication regression correction

The first workflow-dispatch package run was canceled before publication after the user reproduced a Wine 10 → 11 stale-wrapper startup-check failure. No public 0.12.3 tag was pushed. The shared correction is documented in [the dedicated investigation](wine-upgrade-stale-wrapper-2026-11-03.md), including the exact pre-fix reproduction, successful production-helper upgrade/rollback test, 329-test full-suite result and actual Falconeer pending-upgrade recovery. The corrected local DMG was rebuilt and rechecked with all required modules. GitHub checks on the corrected source and final publication evidence follow below when complete.

## Authorized known-issue deferral

After confirming Falconeer ran on Wine 11, the user reported a microphone prompt with its switch Off. The follow-up remains unresolved. The user then explicitly authorized releasing 0.12.3 and targeting that correction for 0.12.4. Release notes disclose the prompt; unsuccessful temporary comparisons are excluded from product source. The original Falconeer launcher identity was restored after the failed rename comparison. See the [open microphone investigation](microphone-off-prompt-2026-11-03.md). CI for implementation commit c07c09d passed all checks, including the real Wine socket matrix; subsequent release-decision changes are documentation only.

## Published release verification

Tag `v0.12.3` resolves to `56a508712564fa1104a4a571dabc4e0da5b86d78`. [Release workflow 41739127649](https://github.com/seastwood/Nokcandu/actions/runs/41739127649) succeeded, as did [final-commit CI 41739125714](https://github.com/seastwood/Nokcandu/actions/runs/41739125714). [Nokcandu 0.12.3](https://github.com/seastwood/Nokcandu/releases/tag/v0.12.3) was published on 2026-11-03 at 23:46:25 UTC as a regular, non-draft release with four assets.

The actual public downloads were retrieved and checked against both GitHub asset digests and the published checksum files:

- DMG SHA-256: `6e0683c3ece97fcae86bd104afbee4ddf2176d60bfb905ea6f46c64fe1007e70`.
- Native IPX corresponding-source archive SHA-256: `40545a75515c3d71717fc1155cbd815deae953b71e3835444a9923928dd5614f`.

The DMG mounted read-only and its app passed deep, strict code-signature verification. Its version is 0.12.3; Wine 10.0 and 11.0 include all three driver components; native IPX manifest checksums pass; launcher/audio helpers are present and their helper-build stamp matches the tested local package. The source archive includes pinned Wine 11 source, Wine driver and packet-module patches, build instructions and license notices. These checks verify the published package, without replacing the user's already-tested local app or modifying running games. The disclosed microphone-Off permission-prompt issue remains open for 0.12.4.

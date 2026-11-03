# Nokcandu documentation

The project README introduces the app. This folder keeps the implementation knowledge, troubleshooting evidence, and development notes that need to survive individual chats.

| Document | What belongs there |
| --- | --- |
| [Installer destination mismatch](investigations/installer-destination-2026-11-01.md) | Why GOG setup bypassed the prepared external folder; shared Inno destination handoff and copy fallback. |
| [Nonblocking installation](investigations/nonblocking-installation-2026-11-01.md) | Separate installation window, retained session, library access and existing Windows-setup preservation. |
| [Graphics detection investigation](investigations/graphics-detection-2026-11-01.md) | Bootstrap launchers, delay imports, unknown API defaults, installed Rocket League regression and review-only migration. |
| [LAN discovery investigation](investigations/lan-discovery-2026-11-01.md) | Battlefield/GameSpy query evidence and reusable diagnostic; LAN browsing restored after the user disabled the Windows host’s virtual Ethernet adapter. |
| [BF1942 Internet browser](investigations/bf1942-internet-browser-2026-11-01.md) | Verified obsolete master hostname, fingerprinted managed-copy correction, safe migration and combined Undo; user confirmed Internet servers appear after the two-slot correction. |
| [Mac native IPX investigation](investigations/native-ipx-mac-2026-11-01.md) | User-confirmed Wi-Fi native IPX discovery/join/gameplay; optional shared component, profiles, registry/file Undo, packet lease and pending final managed migration. | — final managed ROM2 discovery/joining confirmed in both directions; session-based permissions, adapter-redaction migration, and VM snapshot/NAT troubleshooting.
| [Shared IPX and ROM2 investigation](investigations/ipx-rom2-networking-2026-11-01.md) | Optional shared IPX component, native engine/probe evidence, TCP/IP comparison, profile service parity and later multiplayer test. |
| [Engineering learnings](engineering-learnings.md) | Confirmed lessons, the scope of each fix, evidence, unresolved issues, and rules for future changes. Start here. |
| [Compatibility fixes](compatibility-fixes.md) | Component IDs, implementation details, sources, ownership/Undo, migrations, and game/launcher-specific findings. |
| [EA gameplay audio investigation](investigations/ea-gameplay-audio-2026-10-28.md) | The complete dated trial-and-error record for BC2/DAO audio, failed comparisons, restored settings, and remaining questions. |
| [Wine 11 launcher surfaces](investigations/wine11-launcher-surfaces-2026-10-30.md) | Metal surface/presentation and foreign-child hosting fixes; Steam browser-only rendering policy, failed controls and verification limits. |
| [Chrono Trigger media investigation](investigations/chrono-trigger-media-2026-10-29.md) | Confirmed shared GStreamer library-path correction, startup evidence, migration and selected-game restart behavior. |
| [Resizable game-window implementation plan](resizable-game-window-plan.md) | Milestones, architecture, input/scaling, renderer coverage, profiles, launchers, rollback and release gates. Planned work. |
| [Resizable fullscreen-window feasibility](investigations/windowed-fullscreen-feasibility-2026-10-29.md) | Why Wine’s virtual desktop is disabled on the Mac driver, and the requirements for a shared scaling/input backend. Historical research; the driver backend was subsequently implemented. |
| [Development](DEVELOPMENT.md) | Build/release instructions and the historical implementation milestones. |
| [Gaming roadmap](gaming-roadmap.md) | Dated proposals to evaluate; these are not a list of verified fixes or a guarantee of current implementation status. |
| [Release notes](../release-notes/) | User-facing changes grouped by released version. |

## Recording new findings

Update these docs in the same change as the implementation:

1. State the symptom, affected versions/hardware, and how it was reproduced.
2. Separate a confirmed cause from a hypothesis or correlated log message.
3. Record the successful change **and unsuccessful comparisons** worth avoiding later.
4. Identify its scope: shared infrastructure, launcher-specific, game-specific, or one verified binary build.
5. Link the implementation and tests. Say whether verification covered startup, the visible menu, gameplay, sound, input, or restart/update recovery.
6. Explain fresh-install behavior, safe migration, backup/Undo, and unresolved limits.
7. Update the current status when new evidence supersedes a result. Keep detailed dated investigations as historical snapshots.

Keep credentials, account identifiers, raw session logs, copyrighted game/runtime binaries, and machine-specific backup files out of the repository. Use portable paths and record checked hashes instead. A temporary log filename is evidence provenance, not a durable backup.

- [External game launch and storage accounting](investigations/external-game-launch-storage-2026-11-02.md) — native app privacy identity, visible startup errors, external-drive runtime accounting and safe migration/Undo.

- [Clean-runner CI test dependencies](investigations/ci-clean-tests-2026-11-02.md) — remove accidental prebuilt-runtime dependencies from adapter and native-entry unit tests.

- [Microphone-off enforcement](investigations/microphone-off-enforcement-2026-11-02.md) — shared bootstrap policy, capture boundary, launcher separation and tests without recording audio.
- [Recipe storage and user settings](investigations/recipe-storage-settings-2026-11-02.md) — recipe content moves, editable defaults, launcher preservation, profiles and Undo.

- [Microphone permission during playback](investigations/microphone-playback-permission-2026-11-02.md) — fresh-identity reproduction, Off/On eligibility, legacy Core Audio queries, shared clients and Undo.

# Nokcandu documentation

The project README introduces the app. This folder keeps the implementation knowledge, troubleshooting evidence, and development notes that need to survive individual chats.

| Document | What belongs there |
| --- | --- |
| [Engineering learnings](engineering-learnings.md) | Confirmed lessons, the scope of each fix, evidence, unresolved issues, and rules for future changes. Start here. |
| [Compatibility fixes](compatibility-fixes.md) | Component IDs, implementation details, sources, ownership/Undo, migrations, and game/launcher-specific findings. |
| [EA gameplay audio investigation](investigations/ea-gameplay-audio-2026-10-28.md) | The complete dated trial-and-error record for BC2/DAO audio, failed comparisons, restored settings, and remaining questions. |
| [Chrono Trigger media investigation](investigations/chrono-trigger-media-2026-10-29.md) | Confirmed shared GStreamer library-path correction, startup evidence, migration and selected-game restart behavior. |
| [Resizable game-window implementation plan](resizable-game-window-plan.md) | Milestones, architecture, input/scaling, renderer coverage, profiles, launchers, rollback and release gates. Planned work. |
| [Resizable fullscreen-window feasibility](investigations/windowed-fullscreen-feasibility-2026-10-29.md) | Why Wine’s virtual desktop is disabled on the Mac driver, and the requirements for a shared scaling/input backend. Research only. |
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

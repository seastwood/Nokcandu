# Nokcandu development

Fix launcher, engine integration, storage and other shared infrastructure problems centrally for all applicable games. Update shared generation paths and provide a safe migration for affected existing installations; do not solve a general bug with a one-game override. Keep genuinely game-specific settings and recipes restricted to their associated games. Preserve working game content, saves, explicit user settings and manually edited launchers. Test the shared behavior and the reported regression before installing an update.

## Documentation

Keep durable implementation and troubleshooting knowledge under `docs/`, separate from the main README. Update `docs/engineering-learnings.md` and the relevant compatibility notes in the same change as a confirmed fix; keep detailed dated trial-and-error records in `docs/investigations/`. Add new documents to `docs/index.md`. Distinguish verified results from hypotheses and unresolved issues, record unsuccessful comparisons worth avoiding, and state the affected scope, evidence, fresh-install/migration behavior and Undo. Correct superseded conclusions. Do not commit credentials, raw account/session logs, machine-specific backups or game/runtime binaries.

# Nokcandu

For current troubleshooting conclusions and implementation knowledge, start with the [documentation index](index.md). The milestone sections below retain historical development context; they are not a complete current feature inventory.

A small Mac app that turns owned Windows games into normal Mac apps using tested, reviewed Wine recipes.
First version: the two proven recipes — **Worms Armageddon (disc)** and **Generals Zero Hour (Steam + GeneralsOnline)**.

## Build

```
./build-app.sh --test --install     # tests, build, copy to ~/Applications/Nokcandu.app
```

Needs Xcode or the Command Line Tools (Swift 5.9+), macOS 14+.

## What works (milestones 1–2)

- **Library** — finds Wine-wrapper game apps in `~/Applications/Sikarugir`, matches them to shipped recipes, shows icon, edition, and validation status.
- **Play** — opens the game's own app (same as a Finder double-click). Single-instance handling stays in the game's launcher.
- **Check Game** — runs the launcher's own `--check` preflight.
- **Diagnostics** — grouped by layer (app/launcher, Wine runtime, .NET launcher, rendering, display, disc, networking/anti-cheat, running state), with recipe hash checks and recent log tails. "Running" is never reported as "playable". Reports save to `~/Library/Application Support/Nokcandu/Diagnostics`.
- **Screen: Fill screen / Windowed** (Zero Hour) — keeps the three parts of the validated presentation in agreement: launcher arguments (desktop size queried every launch), GeneralsOnline `launcher.json` `windowed`, and `Options.ini` `Resolution`. The launcher gets a one-line, recognisable addition so Finder launches honor the setting too.
- **Reset to Tested Settings** — undoes every Nokcandu change from its journal; returns to Fill screen. Saves, replays, maps and other options are untouched.

Every file Nokcandu changes is backed up first and journaled with before/after SHA-256 (`~/Library/Application Support/Nokcandu/Journals`, `Backups`). A revert never overwrites a file that changed after Nokcandu edited it. Nokcandu refuses to edit a launcher it does not recognise.

## Any Windows game (general installer)

`Install a Game…` → name + source → a new app with its own Windows environment:

- **Windows installer** (.exe/.msi) — runs the game's own setup.
- **Disc image** (.iso) — copy kept inside the app, mounted read-only as D: (volume + raw device), setup from autorun.inf; the launcher mounts it automatically at every start.
- **From your Steam library** — opens the Steam Library browser (below).
- **Steam download (SteamCMD)** — Windows files only, for games that run without Steam.
- **Existing game folder** — APFS-cloned in.

Then: pick the game's .exe (ranked candidates), graphics mode suggested from the .exe's imports (Older 3D = d9vk+KosmicKrisp, Newer 3D = dxvk3+KosmicKrisp, Apple Metal = D3DMetal, Classic 2D = cnc-ddraw, Compatibility = WineD3D), original icon extracted from the .exe, launcher generated from `SharedSupport/nokcandu/game.json`, self-check, play test. Graphics can be switched later on the game's page (journaled, reversible). Only "Older 3D" is validated so far.

Dev: `touch .e2e` before a rebuild runs an end-to-end folder install test (creates and trashes a test app); `touch .sample` captures a `sample` of the running app.

## Shared Steam + Steam Library

- `Steam.app` (Sikarugir folder) is the one Windows Steam for all Steam games that need Steam running. Set it up once from **Steam Library… → Set Up Steam** (SteamSetup.exe from Steam's site, sign in once).
- **Steam Library…** lists games installed in that Steam, games it has seen for your account, and — with your own Steam Web API key (stored in the Keychain) — every game you own. Rows show header art, Installed / In Nokcandu badges, playtime and size.
- **Install in Steam** opens Steam's install dialog (`steam://install/<id>`); **Add to Nokcandu** creates a small Mac app with the game's icon whose launcher calls `Steam.app/Contents/Resources/nokcandu-steam --mode <graphics> --applaunch <id>`. Nokcandu warns when the store says the game has a native Mac version.
- Graphics are fixed when Steam starts. If Steam is running in another mode, the helper asks to restart Steam. Steam runs detached, so game apps return immediately.

## Zero Hour installer (milestone 3 — verified end to end on Oct 24)

`Install a Game…` → Zero Hour builds a **new, separate** app (`Generals Zero Hour (Nokcandu).app`) as explicit, resumable stages:

1. Check this Mac (space, Python, safe target)
2. Prepare engine — runtime cache imported from the working app by APFS clone, hash-verified, with license records
3. Create app · 4. Private prefix · 5. `wine cmd /c ver` engine test
6. **Your step:** SteamCMD in Terminal (`@sSteamCmdForcePlatformType windows`, `app_update 2732960 validate`) — you sign in and approve Steam Guard there; or choose an existing Windows game folder
7. `C:\Games\Zero Hour` mapping · 8. Registry values taken only from Steam's `installScript.vdf`
9. `Options.ini` only if missing (1280 × 800, Medium, AA off)
10. **Your step:** official GeneralsOnline installer and agreements
11. .NET launcher extraction (unmodified, bundle v6 only; unknown shapes stop)
12. Microsoft ICU 72.1.0.3 over HTTPS, pinned per-file hashes, adapter verified byte-for-byte
13. Validated graphics registry values; checks Wine's own d3d8/d3d9 are originals
14. App build (launcher, screen-size helper, original icon, Info.plist) · 15. launcher self-check
16. **Your step:** play test — confirm only if a skirmish actually played well

Progress is saved after each stage (`~/Library/Application Support/Nokcandu/Installs`). "Remove Unfinished Install" moves only the app this install created to the Trash.

## Not done yet

Downloading Wine engines (runtime cache is imported from a working app), checksum manifests for game updates (milestone 4), more recipes (milestone 5), signing/notarization, a Worms installer, and online-play validation.

## Layout

- `Sources/NokcanduCore` — recipes, library, launcher, display controller, diagnostics, change journal, runtime manager, install executor + Zero Hour stages, VDF parser
- `Sources/Nokcandu` — SwiftUI app
- `Sources/NokcanduScreenSize` — prints the scaled desktop size (installed as each game's `Resources/screen-size`)
- `Resources` — kit helpers (`refresh-generals-launcher.py`, `build-icu-adapter.py`), launcher template, icon

## Notarized releases (optional)

Releases are built by GitHub Actions. Without Apple credentials they're signed with the self-made
"Nokcandu Signing" identity (or ad hoc) and macOS asks people to approve the first open. With an Apple
Developer account, add these repository secrets and the release workflow signs with Developer ID,
enables the hardened runtime, notarizes and staples the DMG:

| Secret | What |
| --- | --- |
| `DEVELOPER_ID_P12` | Developer ID Application certificate + key, exported as .p12, base64-encoded |
| `DEVELOPER_ID_PASSWORD` | The .p12's password |
| `NOTARY_APPLE_ID` | Apple ID email of the developer account |
| `NOTARY_TEAM_ID` | 10-character Team ID |
| `NOTARY_PASSWORD` | An app-specific password for that Apple ID |

Switching identities changes the app's signature once, so macOS asks again for permissions such as
Input Monitoring after that update.

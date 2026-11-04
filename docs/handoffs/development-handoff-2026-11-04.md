# Nokcandu development handoff — November 4, 2026

This is the continuation guide for the work recorded in this chat and the linked investigations. It covers the completed 0.12.3/0.12.4 work, what was actually verified, remaining problems, and proposed polish. It is a point-in-time record, not a guarantee that every game works. Read the current source and inspect the current installation before acting on historical local state.

## Start here

1. Read the repository's `AGENTS.md`, this document, and [engineering learnings](../engineering-learnings.md).
2. Start from the latest remote main. Do not resume from the old 0.12.1 checkout or a temporary experimental build.
3. Preserve working games, saves, explicit choices, manual launchers and existing rollback copies. Shared infrastructure defects need shared generation, migration and Repair changes; genuinely game-specific fixes must remain scoped to those games.
4. Treat the current release as the baseline. Prioritize the unresolved microphone consent problem, then targeted profile rollout verification and recovery usability. BF2 fullscreen focus work was explicitly deferred by the user.
5. Keep durable conclusions in `docs/`, detailed experiments in `docs/investigations/`, and new documents in [the index](../index.md). Record failed comparisons and bounded evidence. Do not commit credentials, account/session logs, audio recordings, game/runtime binaries or machine-specific backups.

## Release and repository state

| Item | Verified state at handoff |
| --- | --- |
| Public release | [Nokcandu 0.12.4](https://github.com/seastwood/Nokcandu/releases/tag/v0.12.4), stable, non-draft, published November 4, 2026 at 20:17:36 UTC |
| Release tag commit | `f9539499137b87a313bda4b1a979f585d0b23931` |
| Main before this handoff | `99848f3128c0840b95ad7f95a1d3bd9cb698348a` |
| Latest implementation | `b33b86024a44ef4b6569f1fe3857a42f16665e10` — scoped shared-launcher compatibility |
| Profile catalog | `seastwood/Nokcandu-Profiles`, commit `8f576f2e920b0d4c149c10373f81852e576c345d` — schema 3 support |
| App CI | [41899186139](https://github.com/seastwood/Nokcandu/actions/runs/41899186139), successful |
| Release build | [41902533400](https://github.com/seastwood/Nokcandu/actions/runs/41902533400), successful |
| Engine watcher | [41899229814](https://github.com/seastwood/Nokcandu/actions/runs/41899229814), successful supported-version check |

The latest implementation passed **355 local tests**, with 16 optional skips. GitHub app CI passed 355 tests with 22 clean-runner skips, app packaging, **16 actual Wine socket cases** and **four actual client/child DLL-isolation cases**, across Wine 10/11 and 32/64-bit execution. The release workflow independently passed 355 tests with 21 release-runner skips and packaged the required custom Wine drivers and native-IPX module. Skip counts vary with available integration resources; they do not mean every integration test ran.

The actual public DMG and corresponding-source archive were downloaded. All GitHub asset digests and both checksum files matched. The mounted app reported 0.12.4 and passed deep/strict signature verification; both Wine drivers, native-IPX checksums and the helper-build stamp were checked. Exact hashes and evidence are in [release verification](../investigations/release-0.12.4-2026-11-04.md).

The local Mac received the tested `b33b860` app while it still identified itself as 0.12.3. It was locked during the final optional installation of the public 0.12.4 package, so that substitution was **not** performed. The public update is available through the updater. Do not report the local installed version as 0.12.4 without checking it.

Untracked `.build.backup/`, `.swiftpm.backup/`, `.swiftpm/` and `cpu-monitor.sh` were left untouched. They are not part of these commits; inspect ownership/purpose before any cleanup. Temporary logs, probes and build caches are not durable handoff inputs. This handoff itself changes documentation only.

## Completed work and its evidence

### Installation, launchers, storage and engines

| Area | Shipped behavior and limits | Durable details |
| --- | --- | --- |
| Graphics detection | Shared detector considers launcher/adjacent-game evidence and delayed imports. Unknown requirements no longer automatically become Older 3D; Rocket League prompted this work. Preserve the selected launch/anti-cheat program. | [Graphics detection](../investigations/graphics-detection-2026-11-01.md) |
| Installation window | Library remains usable during installation; installer has a separate retained window. Removed the unconditional Preview badge in 0.12.4. | [Nonblocking installation](../investigations/nonblocking-installation-2026-11-01.md) |
| Installer destination | Improved destination handoff for supported installers. A final copy can still be necessary when an installer ignores the requested folder; do not claim universal direct-to-destination installation. | [Destination handling](../investigations/installer-destination-2026-11-01.md) |
| External-drive launch | Shared native-entry/access handling and visible launch failures replace silent failures. BF1942 opened after local removable-drive approval. No privacy-database bypass. | [External launch and storage](../investigations/external-game-launch-storage-2026-11-02.md) |
| Recipe flexibility | Supported recipe settings and Move To are available. Zero Hour's moved files were hash-checked, preflight passed, and the user confirmed it opened from external storage. Alternate programs/renderers are not all gameplay-validated. | [Recipe storage/settings](../investigations/recipe-storage-settings-2026-11-02.md) |
| Storage performance | Selected sections load on demand, long rows are virtualized, scans coalesce and recent estimates are reused with Refresh. | [Storage performance](../investigations/storage-browser-performance-2026-11-03.md) |
| Storage accounting | Shared resolver includes external launcher game folders and hub-selected private content; rows show per-drive breakdowns. Offline/unknown content produces an incomplete estimate, not a tiny complete total. | [Location accounting](../investigations/storage-game-location-accounting-2026-11-03.md) |
| Move semantics | APFS/Mac OS Extended can move the whole supported app; ExFAT generally moves game files while the app/runtime/private Windows setup stay on the Mac. macOS Storage's app estimate is not proof that an external move failed. | [Move/accounting explanation](../investigations/external-game-launch-storage-2026-11-02.md) |
| Stale installer drives | Track newly created installer-image mappings; clean eligible unchanged mappings after unmount and environment closure. Explicit mappings, game discs and unknown historic mappings survive. Conflict-safe Undo is available. | [Automatic mappings](../investigations/automatic-installer-drives-2026-11-03.md) |
| Store discovery | Background, idempotent discovery adds supported completed installations without requiring the store view to reopen. Stable product/host identity, explicit removal and offline state matter. | [Store discovery](../investigations/automatic-store-game-discovery-2026-11-03.md) |
| Wine selection | Choose verified Sikarugir engines per actual Windows environment, installation default and pre-setup install choice. Shared-host scope is explicit; existing games retain their engine. Wine 10.0 r8 is the original tested default; Wine 11.0 r1 is supported. | [Engine selection](../investigations/wine-version-selection-2026-11-03.md) |
| Wine upgrade | Corrected stale Wine 10 identity-wrapper use during Wine 11 preflight. Clone comparison reproduced the failure, then verified upgrade and exact engine/registry rollback. Falconeer ran afterwards. | [Upgrade correction](../investigations/wine-upgrade-stale-wrapper-2026-11-03.md) |
| App rollback | Managed replacements retain a verified prior app and an independent recovery command. UI rollback and published downloads preserve games, saves and engine choices. | [App recovery](../investigations/app-version-rollback-2026-11-03.md) |

### Settings, profiles, compatibility and repair

- **Save now, apply safely:** settings no longer force a restart. The durable typed queue defers active/unknown sessions, uses fresh activity evidence and serialization, and applies through the same protected path from Nokcandu and app-icon preflight. Live microphone controls remain immediate. [Queue design](../investigations/deferred-game-settings-2026-11-03.md).
- **Apply on exit:** while Nokcandu is open, the background monitor drains eligible pending work after the whole Windows environment becomes idle. It does not reopen the game. Per-control Pending badges identify desired changes; failures retain requests with bounded retries. When Nokcandu is closed, app-icon preflight remains the fallback. [Idle monitor](../investigations/pending-settings-idle-2026-11-04.md).
- **Complete profile application:** local/catalog profiles and note snapshots use `Profiles.applyComplete`, including supported listed compatibility components. Results report unavailable/partial operations. Snapshot Undo tracks newly added components and preserves preexisting ones; individual component Undo remains available. Cinematic/LAV has its separate Undo. A pinned-package BF1942 fixture installed all five components, captured portable IDs and undid the changes. [Profile/component regressions](../investigations/launcher-dx8-and-icon-editing-2026-11-03.md).
- **Catalog parity:** all 13 built-in component IDs and accepted schemas are checked between the app and catalog as data, without executing downloaded validator source. The missing software-audio ID rejection was fixed and the affected profile revalidated. Private profiles use schema 2; newly captured shared-launcher profiles use schema 3 so older apps reject them safely. Schemas 1/2 remain readable. [Catalog parity](../investigations/profile-validator-parity-2026-11-03.md).
- **Shared-launcher fixes:** applicable game-local components work for Steam, Battle.net, EA and Ubisoft. Dedicated registered roots, actual PE programs, stable receipts, complete-path routes, file ownership checks and game-local journals keep rules away from client/other-game settings. Profiles preserve those choices. Failure records are inactive and recoverable rather than exported as working fixes. Battle.net profile graphics/environment and Steam extra environment settings are per game. [Shared implementation, migration and Undo](../investigations/shared-launcher-compatibility-2026-11-04.md).
- **Explicit remaining scope:** shader/compiler libraries, DX9 extras, DX8 translation, matching bundled VC, DXMT cross-process and eligible local settings use scoped routing. Shared IPX/provider setup is still unavailable. Borderless launch wrapping currently supports direct EA starts, not arbitrary client-managed Steam/Battle.net/Ubisoft starts. LAV and PhysX remain environment-wide and labelled. BF1942 executable/menu-copy correction stays verified-standalone only.
- **Program and artwork selection:** mixed launcher/game architectures no longer automatically block a valid adjacent 32-bit DX8 target. Icons can come from another EXE without changing the launch program. Display receipt ownership no longer unnecessarily prevents program changes; the actual recommended-copy recipe still needs safe handling. [DX8, program and icon work](../investigations/launcher-dx8-and-icon-editing-2026-11-03.md).
- **Raw mouse permission explanation:** the Mouse section explains that macOS’s broad “Keystroke Receiving” wording can refer to direct raw input. Preserve opt-in behavior; do not invent a Jump Desktop-specific permission workaround.
- **Repair and activation:** Repair verifies owned audio/input libraries, wrappers, native entries and eligible companion binaries, refreshes per-game policies, and preserves manual edits/links. Installed bytes and loaded helper version are separate facts; live processes need reopening to activate new code. Unknown process state never means safely closed. [Activation/recovery](../investigations/helper-activation-repair-hardening-2026-11-02.md).

### Audio, network and actual game results

| Result | What is confirmed | What not to infer |
| --- | --- | --- |
| CS2 microphone | User confirmed voice reaches the game and On/Off works during play after stable early program identity routing. Status scans moved off the UI actor, resolving the observed settings beachball path. | A tray icon or successful stream open alone does not prove samples; this does not establish universal consent-dialog suppression. |
| Zero Hour playback | User confirmed sound works with microphone Off and no prompt in the tested launch after the shared correction. | Falconeer subsequently reproduced an Off prompt; that broader guarantee remains false. |
| BF2Hub | Shared clean-TCP-close normalization fixed account connection; user confirmed login, servers, joining an Internet match and running around. Normal BF2Hub Play route was retained. | No router port-forward fix was needed for the confirmed bug. Extended sessions/all anti-cheat configurations are not established. |
| BF1942 Internet list | Verified obsolete master-hostname slots in managed copies were corrected; user confirmed servers appeared. Optional game-specific correction is represented in profiles. | Do not patch unrelated executables or assume an EA-protected edition matches verified standalone binaries. |
| BF1942 menu crash | Switching the identified active profile from hardware to software sound resolved the user's menu crash; an online match worked. Optional key-level journalled fix is portable through profiles. | This is a verified workaround, not a proven internal audio-driver root cause or a universal renderer fix. |
| ROM2 TCP/IP | User confirmed joining between Mac and Windows 98. | Same IPv4 subnet does not establish native IPX transport. |
| ROM2 native IPX | Managed Mac launch, local permission, compatible adapter/frame and bridged Win98 VM achieved discovery/joining in both directions. Gameplay started in an earlier Mac-hosted test. VM snapshot had reverted its network to NAT; restoring bridging fixed the last apparent regression. | No Win98 game/system DLL replacement was required. Multi-hour matches, native SPX, Wine 10 native IPX and every eligible game remain unverified. |
| BF1942 LAN | Discovery worked after disabling the Windows host's unwanted virtual Ethernet selection. | Do not classify the host-adapter issue as a general Mac Wine network defect. |

Evidence: [microphone/UI repair](../investigations/shared-microphone-routing-ui-repair-2026-11-02.md), [live switching](../investigations/live-microphone-switch-2026-11-02.md), [BF2 sockets](../investigations/wineserver-closed-socket-readiness-2026-11-02.md), [BF1942 browser](../investigations/bf1942-internet-browser-2026-11-01.md), [ROM2/native IPX](../investigations/native-ipx-mac-2026-11-01.md), [LAN evidence](../investigations/lan-discovery-2026-11-01.md).

Native-IPX packet permission lasts until the last participating game closes; the old 15/30-minute command was an investigation lease, not the shipped match limit. Profiles carry the optional component/frame, never machine adapter identity or administrator approval. Same-subnet Wi-Fi is not automatically incapable: this actual Mac/bridged-VM setup worked. Check observed frames and bridge behavior instead of making a blanket Ethernet-only claim.

### CI and release reliability

The pending-monitor crash occurred only under the GitHub toolchain, at the default async callback path. Nil-injected callbacks and direct production invocation passed the failing runner's tests. The refused-connection probe now handles a valid synchronous refusal as well as strict asynchronous delivery; the historical failure lacked enough data to prove its exact cause. No socket safety assertion was broadly disabled.

The later Engine watch failure happened **before any job steps ran**, because GitHub could not allocate a hosted Mac. Its retry passed. Routine upstream version discovery now uses Ubuntu and requests macOS only for an unsupported engine build comparison. The revised supported-version path passed. [CI evidence](../investigations/ci-pending-monitor-and-refusal-2026-11-04.md).

## Confirmed open issues and prioritized polish

Priority here is a recommendation for the next development cycle, not authorization to silently alter a user's working setup.

### P1 — finish microphone Off consent behavior

**Status:** still open in 0.12.4; explicitly disclosed. Earlier bounded Warcraft/Zero Hour successes did not solve the later Falconeer case. [Read this investigation first](../investigations/microphone-off-prompt-2026-11-03.md).

**Evidence:** Off policy and input-open refusal were present. Consent attempts occurred during `AudioComponentInstanceNew`, before the later input-enable guard. Fresh diagnostic identities and the real path-attributed launcher behaved differently. The precise attribution/call-path cause remains unresolved.

**Do next:** reproduce with a fresh controlled identity and the actual existing game path; identify the earliest request-producing call before choosing a correction. Verify Off means no prompt **and** no capture, while playback continues. Verify On receives non-silent samples and On → Off → On works during play. Cover private/shared hosts, app-icon launches, Wine 10/11, upgrade and Repair paths. Native Mac games have their own input implementation.

**Avoid repeating:** null-format guards, preferred-layout filtering, channel-layout substitution, strict endpoint discovery, output-only component substitution and launcher renaming did not establish a working general fix. Prior Allow/Deny can hide dialogs; a quiet screen or missing usage declaration is insufficient. Do not reset TCC, global audio settings or existing consent to manufacture a pass. Keep audio only in memory and retain levels/results rather than recordings.

**Done means:** fresh and migrated identities demonstrate no Off consent request or capture, working output and real On input/live switching; shared generator, helper activation and Repair regressions pass. Ship no temporary identity rename or diagnostic interposer.

### P1 — finish rollout verification and recovery usability for profiles

**Status:** missing-component and shared-routing implementation is fixed and tested; broad real-game rollout remains bounded. Never promise “100% of every profile/game.”

**Do next:** test representative installed editions through their normal client launch path: apply → idle/deferred apply → launch → capture → restart → Undo. Include private/Steam/EA/Battle.net/Ubisoft, a 64-bit launcher/32-bit game, same-named programs in distinct folders, offline drives, manual edits, failed downloads, repeated application, existing components and recovery records. Prefer fixtures before any user content mutation.

Make unavailable-component explanations, partial results and recovery actions easy to find. Preserve manual edits and old receipts when a game's registered root changes. An existing EA compiler ownership warning was observed during final UI inspection; its changed DLL was preserved. Inspect its current record/content before proposing recovery, rather than force-overwriting it or calling it a confirmed new defect.

**Done means:** clear, actionable status for each component and game, no client/other-game contamination, successful content/setting Undo and no exported local paths. Keep catalog schema/ID parity tests mandatory for future components.

### P2 — broaden supported launch methods, with evidence

Game-local DLL routing is shipped; universal game-start wrapping is not. Prototype scoped borderless wrapping for client-managed Steam/Battle.net/Ubisoft starts only if the actual launch handoff and ownership can be maintained. Research shared-provider IPX separately; do not enable a prefix-wide provider under a per-game label. Keep real scope visible until tested. Extend companion Repair coverage when introducing new helpers.

### P2 — make configuration and actual runtime state easier to understand

Build on existing helper activation reporting to show configured versus actually loaded Wine/renderer/component versions, fallbacks and restart-needed state. Improve explanations of per-game versus whole-client settings and why a queue is waiting. Prefer the affected control plus an actionable summary over forced restarts or unexplained disabled buttons. Do not add UI fields claiming loaded state without process evidence.

### P2 — strengthen storage moves and performance

On-demand sizing and split-drive accounting are shipped. Proposed next work: resumable large transfers, integrity summaries before source removal, interruption/offline recovery, clearer app/runtime versus content versus saves/shared-space display, and stress testing with large slow external libraries. Preserve APFS clone/allocation caveats; “allocated estimate” is not uniquely reclaimable space. Revalidate roots before any cleanup; avoid following arbitrary links or duplicating shared content totals.

### P2 — expand compatibility and recovery evidence

Use a structured result checklist: startup, menu, map loading, actual gameplay, sound, microphone, mouse/keyboard, controller and Space switching. Store game edition/fingerprint, Mac/runtime/renderer and date with the result. Add interrupted-update/rollback, stale-runtime-wrapper, missing companion, external-edited-file and offline-drive scenarios to the maintained integration plan. Keep existing working baselines intact; a menu opening is not enough to replace them.

### P2 — CI/release maintenance

Keep tests on the actual runner/toolchain as well as local Xcode; build errors and runner-capacity failures need different handling. Retain Wine 10/11 × 32/64 socket and child-routing cases. Current successful workflows warned that v4 checkout/cache actions target deprecated Node 20 and are forced to Node 24; upgrade supported action versions in a separate reviewed/tested change. Do not combine it with unrelated game fixes. Consider measuring/caching repeated native build preparation to reduce release latency without weakening required module/source checks.

### Deferred — BF2 fullscreen Space return input loss

User explicitly deferred this because disabling the resizable virtual screen works better. Preserve that Off choice. [Full investigation](../investigations/fullscreen-space-input-2026-11-03.md).

Keyboard/mouse initially work, then stop after a Space-away/back cycle in the fullscreen virtual screen. Window shrink/minimize/restore recovers them. A guarded deferred focus re-offer passed native tests but **failed the actual game comparison**. Candidate and trace driver changes were removed from active source/builds; no confirmed fix shipped. An initial hang and focus loss must not be assumed to be the same defect.

Resume only with a complete correlated native/Windows activation and focus event sequence, ideally another affected game too. Test repeated Space transitions and ordinary windowed input, with exact production-driver restoration available. Do not reintroduce the failed candidate or read/log actual keystrokes.

### Historical reports needing revalidation, not automatic fixes

BC2/Dragon Age: Origins repeating gameplay audio was not resolved by the older comparisons. BC2 positioning also lacked a reliable repeated-launch result in that report. Recheck current engines, settings and symptoms first; later display recommendations do not establish that the old audio bug vanished. Obtain an actual sound-bearing comparison with user agreement before another override. Failed DSOAL/synchronization/renderer/device experiments must not become defaults. [Historical audio investigation](../investigations/ea-gameplay-audio-2026-10-28.md).

### Longer-term proposals

- Safe test-copy trials covering environment/configuration/registry/components and saves, with an explicit working baseline.
- Actual frame-time/performance comparisons using a supported scene or built-in benchmark; evidence-based choices for fanless machines.
- Better profile ranking by comparable hardware/runtime evidence, while retaining manual choice and Undo.
- Broader controller/input coverage based on real supported games.
- Optional extraction of native-IPX source into a dedicated repository. This was discussed, **not implemented or required for 0.12.4**. If pursued, pin source revisions, retain notices/corresponding-source compliance, preserve reproducible build and normal bundled-module delivery. Users must not need a manual source download just to play.

The [older gaming roadmap](../gaming-roadmap.md) contains useful proposals but predates several completed features. Its shared-program routing proposal is now implemented; its old universal presentation discussion must be read alongside the current resizable-window implementation and deferred BF2 limit. Do not treat the old roadmap as the current bug list or copy third-party code without a separate license review.

## Code map for continuation

Paths below are relative to the repository root.

| Responsibility | Start reading |
| --- | --- |
| Complete profile apply/capture/Undo | `Sources/NokcanduCore/Profiles.swift`, `Tests/NokcanduCoreTests/ProfileCompletenessTests.swift`, `SharedGameCompatibilityTests.swift` |
| Components, payloads, ownership | `CompatibilityFixes.swift`, `SharedGameCompatibility.swift`, `ChangeJournal.swift`, `CompanionRepair.swift` under `Sources/NokcanduCore/` |
| Registered roots and launcher handoff | `LauncherInstallation.swift`, `HostedSettings.swift`, `Launchers.swift`, `BattleNetGraphics.swift`, `CustomGame.swift`, `SharedSteam.swift` |
| Deferred settings/status | `PendingSettings.swift`, `PendingSettingsMonitor.swift`, `PendingSettingControls.swift`, `Library.swift` (includes `GameLauncher`), `Sources/Nokcandu/AppModel.swift` |
| Native audio/input/routing/socket helper | `Resources/rawmouse/rawmouse.m`, its adjacent headers; `GameMicrophone.swift`, `RawMouse.swift`, `HelperPatch.swift`, `HelperActivation.swift` |
| UI scope and program chooser | `Sources/Nokcandu/FixesSection.swift`, `HostedGameSettingsSection.swift`, `GameDetailView.swift` |
| Storage/install/discovery | `GameFolders.swift` (includes `GameMover`), `StorageInventory.swift`, `Storage.swift`, `InstallerDestination.swift`, `StoreGameDiscovery.swift`, `AutomaticDriveMappings.swift` |
| Engines and rollback | `RuntimeManager.swift`, `AppUpdate.swift`, `AppRollback.swift`, `LauncherEntry.swift`; `Engine/winemac/`, `Engine/wpcap/` |
| Native IPX | `NativeIPXNetworking.swift`, `IPXNetworking.swift`, `Resources/native-ipx/`, `Tools/native-ipx/`, `Tools/ipx-probe/` |
| Catalog/release checks | `Tools/profile-check/`, `Tools/socket-events/`, `Tools/program-fixes/`, `.github/workflows/`, `build-app.sh`, `make-dmg.sh` |

Unless shown otherwise, Swift filenames in this table belong under `Sources/NokcanduCore/`. Confirm current names before editing; this map describes the handoff revision.

## Verification workflow for the next change

Run focused meaningful tests first; use the complete suite and required packaging before installing shared infrastructure changes. Some commands require local toolchain/network permissions.

```sh
swift test
NOKCANDU_REQUIRE_WINEMAC=1 NOKCANDU_REQUIRE_NATIVE_IPX=1 ./build-app.sh
```

For the pinned-package profile regression after building resources:

```sh
NOKCANDU_E2E=1 \
NOKCANDU_RESOURCE_ROOT="$PWD/build/Nokcandu.app/Contents/Resources" \
swift test --filter SharedGameCompatibilityTests.testBF1942SharedProfileInstallsAllFiveComponentsAndUndoes
```

Read `Tools/socket-events/README.md` before running the real-Wine matrix. `Tools/socket-events/ci.py` provisions pinned official runtimes/compiler; `Tools/program-fixes/probe.py` tests actual Windows parent/child DLL isolation. These use disposable prefixes, not real games. The catalog's `scripts/test_profiles.py` and the app's `Tools/profile-check/check-fix-ids.py` must agree on IDs/schemas whenever either changes.

For releases, follow the established VERSION/release-notes/tag workflow. Require green implementation CI, required driver/native-IPX packaging and actual public download verification. Check stable/non-draft status, tag/version agreement, asset hashes, app signature, required modules and source notices. Do not call a queued run or a local test pass a successful GitHub release. The public source archive is an associated compliance/build asset; it is not installed as the user's runtime.

## Suggested first work session

1. Verify current local app version and inspect the working tree without removing untracked content. Update through the ordinary recovery-aware app replacement path when convenient.
2. Reproduce the microphone-Off consent issue safely against fresh and existing identities; preserve the current working On/live-switch baseline.
3. Add a focused regression for the actual failing call path, implement centrally, verify migration/Repair and all required audio modes, then use a real affected-game comparison.
4. Separately test representative shared-launcher profile lifecycle cases and improve any confusing partial/recovery UI revealed by those tests.
5. Pick the next measured polish item from the priorities above. Keep BF2 focus deferred unless the user resumes it or equivalent evidence changes the scope.

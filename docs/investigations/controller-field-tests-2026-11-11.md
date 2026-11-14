# Controller field tests - November 11, 2026

Source: user's 11-page PDF `11-11-26 page1 Tests:.pdf.pdf`, reviewed as rendered pages and extracted text. Eleven embedded images are readable alongside their associated notes. Page 4's app screenshot is followed by the physical controller photo on page 5. These are user observations, not automated acceptance results. Preserve the original report outside the repository; no account or machine logs copied here.

| Page | Finding / requirement | Status and next check |
| --- | --- | --- |
| 1 | Trackmania warns only 3.4 GB page file/committed memory, recommends 5 GB | November 13, 2026: cause found — Wine counts only free + inactive memory plus unused swap, and macOS swap grows on demand. Fixed in the Wine helper (see engineering-learnings, "Windows commit checks see macOS's growable swap"); awaiting a Trackmania start to confirm. |
| 2 | Two Pro Controllers; only lower entry responds | Pending: correlate physical Nintendo and Apple/SDL aliases with real reports before suppressing anything. SDL Pro is not evidence of Valve detection. |
| 3 | Pro mappings wrong in Trackmania; Xbox detected but no game input | Pending: test native, SDL and XInput identities/mapping separately; preserve Steam Input choices. |
| 3-5 | Wired Steam reports work; dongle does not. Need trackball mouse, optional stick/WASD, gyro, touch activation, adjustable edge actions, accurate layout, rumble, no firmware desktop duplicates, sustained holds | Partial wired passive implementation; full device ownership/restore, receiver transport, IMU enabling, trackball and haptics pending. Photo confirms actual relative control positions. |
| 5 | Overwatch virtual-screen aiming now works | User tested; do not erase remaining reliability limitations. |
| 5 | Gyro sometimes stops until reconnect; calibration lost on window changes | Investigating focus-driven engine destruction and competing motion handlers; do not claim sensor recovery from software tests. |
| 5 | Overwatch ordinary fullscreen pointer offset grows down/right; 1470x956 avoids it | Pending: scale/coordinate-space regression; preserve requested resolution. |
| 5-7 | Battle.net external app lacks display settings shown for managed game | Pending: shared external-launcher settings capability, safe generation/migration. |
| 7 | BF1942/BF2 controller clicks jump in virtual screen, physical pointer does not; raw toggle makes no difference | Critical pending: socket relative movement versus CGEvent absolute button coordinates. |
| 7 | BF controller aiming no longer hits edge | User tested, separately from unresolved button coordinates. |
| 8 | Controller Control+arrows fail Mission Control/Space shortcuts | Pending: verify synthetic modifier flags, event source and system shortcut receipt. |
| 8 | Replace “As underneath” with “Inherited” | Implemented in source: “Inherited” / “Inherited action”; serialized inheritance semantics unchanged. Installed signed build verified in the live profile editor. |
| 9 | Copy existing layer into another profile | Pending dependency-aware layer import, collisions and inherited settings. |
| 9-10 | Mouse/gyro direction selects held radial menu; automatic action names with editable titles | Implemented / engine-tested / installed UI verified; physical-pointer acceptance pending. Existing stick modes/titles retained. |
| 11 | BF1943 installer cannot accept shown executable | Pending: shared program-selection validation; screenshot shows candidate path with a backslash in displayed filename. Investigate path normalization before workaround. |
| 11 | Overwatch shader stutter; asks whether ESync/MSync used | Pending: inspect actual launch env/cache lifecycle, distinguish shader compilation from thread synchronization; no unsupported performance promises. |

## Previous-session evidence carried forward

The installed app passed 212 related tests, zero failures/skips; stable signing and bundled-helper checks passed. The temporary unassigned editor fixture was removed. Physical wired Steam receipt identified A, left/right grips and both pads with production decoding (224 valid states in extended check); rotation reports remained zero. Sensor activation is still pending, not certified working.

Windows native vendor-interface access and GET_ATTRIBUTES query succeeded, and actual USB interface 2 is preserved. Official HIDAPI still reports unknown bus/interface: Wine's CM_Get_Parent is a stub. A wider SetupAPI/kernel experiment is isolated to a disposable engine/prefix and is **not installed**. Its first comparison prevented Winebus startup; building a companion Unix kernel failed because this Wine build has no such target. Do not ship that candidate. Baseline SetupAPI devinst: 4,346 checks, zero failures, 125 expected todos.

Physical keyboard typing returned to normal after closing both apps; user verified Nokcandu alone and Windows Steam alone are normal. Combined fresh-start reproduction remains pending. No keyboard settings or Steam Input settings were changed, and doubled typing is not declared fixed.

## Scope and Undo

This intake does not change profiles, settings, launchers or game content. Each implementation below must record focused tests, hardware limits, migration behavior and Undo. Unverified requirements remain pending after unrelated tests pass.

## Increment 1: unchanged-profile focus transitions

Confirmed in source: `DesktopPad.evaluate` released outputs on every new foreground PID, then forced engine destruction even when compiled profile and selected source were unchanged. This discarded measured gyro bias. The unchanged-profile focus path now reuses its released engine, clears physical-source snapshots, and reattaches callbacks. Old application's keys, toggles and mouse outputs still release before PID handoff; subsequent physical reports can populate the new application. Actual profile/source changes and forced rebuilds still take the existing path.

A production-engine regression check calibrates a nonzero sensor bias, holds a key and toggle, releases for focus change, verifies both releases and zero stationary drift, then verifies a new button press and intentional rotation still work. Thirty-one focused controller/head/mouse/source/privacy tests passed, zero failures. This verifies the engine contract; it does not simulate AppKit foreground transitions or certify the reported hardware stall fixed. Switching to a different/no profile still rebuilds and does not carry calibration across profiles. Runtime acceptance remains pending.

No on-disk profile migration is needed; stored settings, game content and assignments remain unchanged. Undo is the previous signed app build. UI inheritance terminology changed independently without modifying serialized binding semantics.

### Installed validation

Expanded related suite: **213 tests, zero failures/skips**, including privacy tests. Native build-script suite: **12 tests passed**, covering actual helper interposition, coordinate conversion, controller HID allow/deny/Pro descriptor and signing. Signed production build, deep/strict verification and signing continuity passed. Installed using managed recoverable app replacement, reopened the exact installed path, and observed the updated “Inherited” choice in Overwatch's MacOS layer. No profile edits were made during UI verification. Battlefield 2 remained running throughout; no game or launcher was closed. The test confirms packaging/UI and software contracts, not game-specific resolution of any still-pending input issue.

The click-path investigation found `DesktopPad.move` uses the Wine socket while `mouse` posts a macOS CGEvent at the physical/capture pointer. `pad_post_relative` can move the Windows cursor without moving that pointer. Existing `game_cursor` click correction is opt-in and restricted to raw aiming, so it does not cover every controller route. This is a confirmed architectural mismatch, but reproducing/fixing event ordering, Wine cursor semantics and scaled menu coordinates requires a shared helper/driver check; no speculative button rewrite is installed in this increment.


## Additional BF2 report

User supplied an animated-world/missing-deployment-menu screenshot after this report. It is tracked separately from click routing in [BF2 deployment-menu investigation](bf2-deployment-menu-2026-11-11.md). Supported per-game candidate implemented and software-tested; actual map acceptance pending. The user closed BF2/BF2Hub normally for activation and later explicitly authorized routine interruptions for progress.


BF1943 follow-up: the remaining unfinished setup was not found in the inspected library/installer records. The screenshot's displayed name may contain literal backslash separators; this remains a hypothesis until the original folder is inspected. No filename/content migration is applied speculatively.


Final November 11 full-suite check: **589 tests, zero failures, 19 optional integrations skipped**. Privacy tests all pass. Mouse/gyro menu picker and automatic-title guidance observed in installed editor; old titles remain. BF2 menu file transport verified against actual legacy DXVK in isolated prefix; new D3D9 performance comparison pending. Both Wake Island and Dalian Plant had positive user menu tests before final transport activation, so causation is not certified.

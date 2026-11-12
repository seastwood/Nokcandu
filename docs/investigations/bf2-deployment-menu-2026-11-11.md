# BF2 deployment menu missing - November 11, 2026

## Report and evidence

User screenshot shows the map/world and control-point marker with no spawn/kit selection UI. User reports animated water/audio and only some maps affected. This is separate from controller click-position problems and previously deferred native fullscreen Spaces input loss. No frozen-renderer conclusion follows from the screenshot.

The installed private BF2 environment uses BF2Hub, Older 3D games, DirectX 8 compatibility's legacy D3D9 path, and borderless. The actual resizable-window setting is 1920x1200 (verified in the live UI and `resizable-window` file). The deprecated `game.json.windowedPresentation` field is nil; that must not be interpreted as Off. The actual BF2 graphics log identifies **DXVK-Sikarugir v2.3**, with only `d3d9.longMad` built in; it lacks the later BF2 focus-loss default. Both architecture copies of the actually selected renderer contain the supported `d3d9.deviceLossOnFocusLoss` option. Renderer label alone is insufficient to identify the loaded implementation.

Upstream [DXVK issue 3651](https://github.com/doitsujin/dxvk/issues/3651) describes an invisible but interactive BF2 respawn/kit screen. [PR 3797](https://github.com/doitsujin/dxvk/pull/3797) adds `d3d9.deviceLossOnFocusLoss = True` specifically for BF2/BF2142; [2.3.1 release notes](https://github.com/doitsujin/dxvk/releases/tag/v2.3.1) include that correction. This is a credible supported test, not proof that every map-specific symptom has the same cause. No renderer replacement, executable patch or reset of user settings is needed to test the supported option.

## Implementation and scope

New opt-in `bf2-deployment-ui` compatibility component appears as **BF2 deployment menu recovery** under Wine & Fixes. Eligibility checks a private BF2/BF2Hub environment, actual BF2 data, Older 3D mode and supported selected renderer. Shared environments are explicitly unavailable; unrelated games do not gain this behavior. The final component owns a small BF2-scoped `dxvk.conf` beside BF2.exe plus a Windows C: `DXVK_CONFIG_FILE` path and the feature flag in its normal receipt. Existing user configuration files/custom file selections are refused and preserved. A later renderer may also read the inline append, but the legacy renderer requires the file. Undo restores its prior environment keys and removes only an unchanged owned file. It does not alter BF2Hub, launch arguments, renderer selection, map files, account data, saves or game profiles. The UI identifies gameplay verification as experimental.

Existing component installation provides restore points, running-session refusal, managed launcher regeneration/manual-edit protection, profile inclusion and conflict-aware Undo. Existing/fresh installs are unchanged unless this option is explicitly installed. Saved profiles reference the built-in ID only; settings are regenerated on the receiving installation. Undo removes the owned flag and leaves other environment/user edits intact. Restart BF2 and BF2Hub for apply or Undo.

## Validation

Three new tests exercise actual shell merging, opt-in/graphics isolation, component installation and Undo, saved-profile inclusion, later-edit preservation and unsupported-renderer/game refusal. Initial focused combined result: 30 tests, two existing optional tests skipped, zero failures. Expanded regression/package/game results must be recorded below. Gameplay is **pending**, not resolved.


## Live activation caught a preservation regression

The first GUI component installation wrote its receipt and owned flag at 17:24:11 UTC. At 17:24:20 UTC the general settings journal showed another generated-launcher/settings write restoring the previous configuration, without the flag. This demonstrated lost activation despite the Installed badge. The exact writer of that live overwrite was not correlated; do not assert one exclusive cause. Inspection found stale snapshots in automatic launcher/helper maintenance and queued full-custom settings that did not preserve component requirements.

Central correction: `CustomGames.upgradeLaunchers` and `HelperPatch.refresh` re-read the actual installed configuration before regeneration and reconcile owned settings from component receipts. Pending custom-settings application preserves installed component requirements using the same policy already used by saved profiles. Explicit component Undo remains separate and can remove the owned flag. Hash checks still protect manually edited launchers, running sessions are skipped and no generic game preference is reset. This applies to all installed compatibility components, not just BF2. Existing cold maintenance safely repairs this observed missing owned setting from its receipt.

Regression coverage queues an old custom snapshot before component installation, applies it afterward, verifies both the new user arguments and retained component flag, then runs maintenance with the old library object and confirms no stale reversion. It also deliberately removes the owned flag while retaining its receipt and verifies cold maintenance repairs it without losing later arguments. An initial test fixture lacked an executable Wine entry, so the real queue correctly refused it; the completed disposable fixture supplies a harmless executable stub and isolated queue state. Final combined run: **267 tests, two optional skips, zero failures**. Skips require official download/build packages (shader compiler E2E and BF1942 shared five-component E2E), not privacy exceptions. **12 native build-script checks passed**. Production packaging, deep/strict signature and signing continuity passed; final signed app installed with recoverable replacement.

The user authorized routine interruptions. BF2 was closed through Nokcandu's existing Quit control; a non-forced Windows taskkill request closed the remaining BF2Hub process (no `/F`, no unrelated environment killed). After final app restart the live configuration flag and launcher append were verified present, and remained present after the normal Play route reopened BF2Hub. The BF2 UI exposes Installed and Undo. No renderer, game content, map files, user shortcuts or unrelated system settings were changed.

## Gameplay result and limits

The user identified Wake Island as affected, then reported that **Dalian Plant's menu appeared on the first test**, where it had previously failed. Record that positive observation, but the first session's graphics log did not establish the new option active and its saved flag had been reverted. Therefore that result alone does not prove causation. The corrected durable activation is now verified on disk/launcher; Wake Island, repeated Dalian Plant loads and switch-away/back still need acceptance with the corrected launch. Original controller click jumps, general fullscreen scaling and hardware motion stalls remain separate unresolved issues.


## Superseding legacy renderer transport verification

The initial inline-only activation is superseded. Actual legacy D3D9 library inspection found the supported option and `DXVK_CONFIG_FILE`, but no `DXVK_CONFIG` string. Its real graphics log did not report the inline option. The fresh ordinary renderer does support inline configuration; do not generalize from its capabilities to the compatibility bridge.

A no-window/no-render D3D9 initialization probe was compiled from `Tools/graphics-probe/d3d9-config.c` and run in a disposable prefix using the actual legacy renderer. It initialized successfully and logged **Found config file** and **d3d9.deviceLossOnFocusLoss = True**. A second run named the harmless probe BF2.exe and verified the exact `[BF2.exe]` scoped section. No game executable was copied or modified for that probe. A minimal-shell launch initially failed; Nokcandu's normal WineTools environment succeeded. No actual user game was used for isolated transport testing.

The component now writes that scoped file through its normal conflict-aware journal and selects it by logical Windows C: path, independently of BF2Hub's working directory. Existing flag-only receipts offer Update with original Undo values retained. A first live update refused a linked external folder because Foundation leaves a nonexistent leaf's parents unresolved. The correction resolves the legitimate game directory before appending the new filename and independently rejects a file-level symlink. A regression covers a missing file under a linked parent. This is not permission to overwrite existing user dxvk.conf files.

## Additional user gameplay/performance feedback

The user subsequently reported the menu appears fixed in **Wake Island and Dalian Plant**, but performance poor in both tested graphics choices. Those map observations preceded final file activation and must not be treated as proof of the inline candidate. Current actual process inspection under selected DXMT found Wine's `d3d9.dll` plus `wined3d.dll` and Apple OpenGL, not DXMT rendering. BF2 uses DirectX 9. System memory free percentage was 54%, game resident memory about 405 MB and CPU about 116% at one sample; that is not evidence of memory-pressure stalling. No FPS performance improvement is claimed from that sample.

The user had removed DirectX 8 compatibility (legacyD3D9 nil). Selected **Older 3D games** for a controlled comparison with the normal newer D3D9 path, preserving other game settings. This is reversible via the ordinary graphics picker. Renderer-module/log confirmation and user FPS/gameplay comparison remain pending. The resizable screen remains 1920x1200 and no resolution/game-quality reset was performed.

Final combined automated run after the linked-parent correction: **273 tests, zero failures, two optional package/download-dependent skips**. Native checks and final installation/activation receipt are recorded below when complete. Privacy tests passed; no overall/full-repository success is claimed.


## Final central ownership safeguard and full-suite results

A later live write again dropped the selected config-path key after the component file existed. Rather than relying exclusively on identifying selected maintenance writers, **ordinary CustomGames.save now retains receipt-owned environment and DLL rules centrally**. The component's explicit Undo is the only caller that opts out. Other config fields (graphics, arguments, display-recipe flags) keep their existing save semantics; the safeguard does not force all of a stale snapshot's non-environment fields from component policy. Maintenance and queued edits retain their earlier protections. The exact later live writer remains uncorrelated, so no exclusive cause is asserted.

Tests verify an ordinary stale save cannot remove either BF2 flag or config-path key, explicit Undo removes both, unrelated later edits survive, and legacy on-disk loss repairs through cold maintenance. The simulated legacy fixture must include a matching old generated launcher/hash; a mismatched old JSON alone correctly triggered manual-launcher protection. That initial test expectation was corrected rather than weakening the hash check.

**Full repository test suite: 589 tests, zero failures, 19 skips**. Skips require optional owned-game installations, explicitly enabled E2E fixtures, verified package downloads/native release modules or pre-migration BF1942 content. None is a skipped privacy regression. All privacy tests passed. Source was rebuilt from that exact final revision before installation. The prior 273-test result is the earlier selected regression suite, not the total full-suite count.

Mouse/gyro radial menu software checks and installed picker/title guidance were verified in an existing, unassigned Steam Controller profile without changing mappings or assignments. See the separate menu investigation for scope and pending physical acceptance.

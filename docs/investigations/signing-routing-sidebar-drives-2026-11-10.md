# Signing, motion pause, routing and sidebar follow-up — November 10, 2026

Continuation of the [controller overhaul](controller-overhaul-2026-11-10.md). User authorized installing builds; specific permission restoration was also authorized. Do not treat that as authority to force-close games or delete drive aliases/save data.

## Progress checklist

| Request | Status / evidence / remaining gate |
| --- | --- |
| Keep permissions across builds | Implemented fail-closed configured-keychain selection and local-install identity continuity guard; nine hermetic script tests passed. Existing Nokcandu certificate found with ordinary keychain access; two different temporary binaries signed by it have identical default designated requirements. Actual changed-code signed update retained effective Accessibility without another grant; installed executable path verified. Further same-signer update installed. Transition from ad-hoc remains a one-time grant refresh. |
| AirPods/headphone input question (original session design; superseded below) | Experimental documented CoreMotion path exists; head-to-mouse, session opt-in. Manager creation is now deferred until explicit Enable, and old-session callbacks are rejected. This prevents settings/quit from constructing the manager while disabled; the user's earlier prompt cause has not been independently reproduced. Hardware/audio acceptance still pending. |
| Gyro-off hold also pauses headset | Implemented shared explicit off-hold query, app routing gate and transform reset while paused. Tests cover multiple off owners, on-versus-off precedence, edit/disconnect/full cleanup and no jump on first resumed sample. Controller gyro output may be Off while independently opted-in head input works; explicit off holds still pause both. |
| Sidebar buttons overlap games | Implemented reusable footer layout outside the list, clipping list content; used for Games and Profiles. Installed screenshot/AX verified separate footer, divider and clipped list. |
| Search below Games/Profiles | Explicit sidebar search field placed beneath selector, with clear control and Command-F focus (including switching from Profiles to Games). Native sidebar search no longer inserts itself above selector. Installed section-first ordering, Command-F, filtering and Clear verified. |
| As-itself route / empty Wine panel | Confirmed offline alias-writing defect; CurrentControlSet registry links now resolve to actual ControlSetNNN. Seven controller/alias tests passed. Shared idle migration preserves original registry backup and advances the marker. Unknown process inspection now refuses writes. Native enumeration reproduced failing with the helper, succeeding without it; scoped SDL hook comparison restores Pro Controller detection. Installed real Steam prefix now lists Pro Controller in DirectInput and the actual Windows panel. Native VID/PID verified; button/gyro/game acceptance pending. No live prefix rewritten. UI descriptions corrected to requested policy rather than claiming Wine detection. |
| Profile headphone source | Implemented/tested and installed: Add Device source, saved tuning, inherited disable/removal and backup. Actual installed chip/inspector/disable/remove checked in an inactive temporary profile. Real head motion/audio remains pending. |
| Toggle/sequence test preparation | Implemented/tested and installed: held-output observation, timed 32-transition history, focus-incomplete warning and local Copy Test Report. Installed ordinary key/click/focus/reset checks passed; actual controller tests pending. |
| Duplicate external-disk letters | Confirmed E/F/H map to one mount with different raw device numbers. Wine add_drive compares raw device numbers and reserves stale links; root mechanism found. No aliases removed, renamed or retargeted. Reliable live/restart prevention and ownership-safe migration still pending; preserve game references. |

## Signing evidence and scope

Installed ad-hoc DR was a binary-specific cdhash. Apple [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) explains code identity, privacy grants and mutually compatible requirements; [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/) covers self-signed identities. No identifier-only/custom weakened requirement was introduced.

The restricted command context reported zero identities, but normal keychain access exposed the **existing** Nokcandu Signing identity and dedicated keychain. Existing private password/certificate files are present; no secret contents were printed/exported, no new certificate generated, no ACL/trust-store edits. The existing signing keychain was unlocked using its pre-existing local credential. Two different compiled C binaries signed with this identity and the same signing identifier verified successfully and produced the same certificate-bound DR. This is empirical identity continuity, not yet a live TCC retention result.

Build preflight now resolves signing before compilation. Configured-but-inaccessible/missing identity fails instead of silently falling back to ad-hoc. Explicit ad-hoc build remains available for isolated diagnostics. `--install` checks the incoming app against the installed certificate-signed app's actual codesign requirement; incompatible updates fail unless a deliberate signing transition is explicitly selected. Ad-hoc-to-stable is permitted as the one-time migration. Existing Developer ID overrides/hardened signing remain supported. This guard is for the local build/install path; direct recovery-tool intentional transitions and remote distribution-channel migration remain separate. Keep the same certificate/private key and bundle identifier for later development builds.

Nine shell tests use fake security/codesign tools and temporary fixtures, never real keys: identity selection, explicit override, denied unlock, missing password/identity, same-signer install, incompatible refusal and intentional transition. Default production paths are unchanged; optional custom keychain/password-file paths support fixture/CI isolation. No system HOME variable was repurposed.

## Wine routing findings

Read-only inspection observed a saved native policy but an older Xbox applied marker and stored maker overrides still zero. The registry persists `System\\ControlSet001` and represents CurrentControlSet as a `#link` with UTF-16 `SymbolicLinkValue`. RegistryText previously edited literal CurrentControlSet children instead of following this alias, while tests used unrealistic files without the link. Fixed centrally for set/remove; supported targets are only same-hive `System\ControlSetNNN`, malformed/unsupported explicit links fail without changing registry bytes.

Tests use a wrapped UTF-16 link to **ControlSet002**, proving the code doesn't hardcode 001. They verify native maker settings, automatic cleanup in the real section, unrelated settings preserved, malformed-target refusal, unknown-process refusal, one-time original backup and idempotent marker migration. Backup: `system.reg.pre-controller-routing-v2`; restore only with the environment fully closed and after preserving later wanted changes. Versioned `v2:<effective mode>` marker causes old installs to reapply on their next verified idle refresh. Fresh and existing environments use this same path; no one-game override.

`WineTools.ownedProcesses` returned an empty list on failed process enumeration. Controllers set/refresh now instead require a reliable fresh process snapshot before any registry/backup write. A failed inspection is unknown, never closed. No attempt was made to repair a running Steam prefix in this session. Device detection remains a separate gate.

Correction: a `DisableInput=1` value was also observed, but Wine 11 source shows this option controls the UDEV/input path, while Mac IOHID startup is gated separately by DisableHidraw. It is **not established** as the cause of the empty Mac Wine panel. Do not repeat commentary implying that this single value disables all Mac controller input. The alias/mode drift is reproducible; actual Pro Controller detection needs a clean environment restart and device-open evidence.

Read-only USB HID inventory observed Nintendo 057E:2009 Pro Controller as generic-desktop joystick, and Valve 28DE:1142 Steam Controller interfaces as keyboard/vendor pages. No raw reports or device-mode writes. Local pinned Wine 11 `bus_iohid.c` accepts joystick/gamepad usages and rejects other interfaces; original Steam hardware needs a specialty/SDL path rather than assuming native IOHID handles it. USB transport alone doesn't certify wired-versus-receiver/firmware support. No Steam process was killed.

## Duplicate-drive findings

The user-visible aliases point to the same mounted folder; their double-colon raw-device links refer to distinct old `/dev/rdisk…` values. A raw-only G double-colon entry also exists. Wine 11 `mountmgr.sys/diskarb.c` uses current BSD device names for notifications; `unixlib.c:add_drive` matches existing raw device identity and treats dangling links as occupied. macOS reconnect renumbering can therefore consume another letter. This supports the reported reconnect mechanism; no unplug/replug trial was performed.

Do not delete duplicates merely because target paths match. Games/Steam libraries/registry may reference any existing letter, manual mappings may be deliberate, mount names can be reused by different physical volumes, and raw device numbers are not stable volume identities. A durable fix must use stable volume identity, cover live notification and restart paths, keep existing aliases that are referenced, and offer Undo for any managed-only cleanup. Existing automatic cleanup only owns newly observed disk-image mappings; it does not own these external-SSD aliases. No risky adoption/deletion has been made.

## Verification to date

174 selected controller/profile/privacy/process/drive tests passed with normal process visibility, zero failures/skips. In the restricted command context the expanded selection had two drive-undo failures caused by denied process inspection. An unchanged HEAD baseline reproduced the same two failures (seven drive tests); the drive implementation/tests were unchanged at that point. This is an environment limitation, not evidence that unknown-process safety should be relaxed. Earlier four privacy failures have separate baseline/fixture evidence in the main investigation.

Sidebar/search are reversible layout changes; app compilation checks accompany actual visual acceptance. No mirrored layout-unit tests added. Head-motion transforms and shared off-hold state have deterministic tests; actual AirPods prompts, motion/audio behavior and game consumption remain unverified.

## Explicit native precedence and actual installed UI checks

A second independently reproduced routing defect emerged after the alias repair: `Controllers.effective` forced every non-hidden policy to Xbox whenever any shared-environment profile required the driver. In the real shared Steam prefix, there was no direct pad-map for the selected game, but other shared profile routes caused the effective mode/marker to remain Xbox despite a saved native choice. Fixed precedence: only **Automatic** may adapt to the profile driver; explicit Native/Xbox/Hidden are honored. A new shared-profile fixture verifies native overrides profile-driver presence, while Automatic still selects Xbox and native updates the real ControlSet/marker. Thirteen targeted routing/head-motion tests passed. Existing automatically selected behavior is preserved; an explicit native route intentionally does not use Nokcandu's SDL controller remapping/suppression. Updated the profile warning to explain this tradeoff rather than silently overriding the user.

The first full certificate-signed app passed deep strict verification in normal keychain context and was installed with app-only recovery. Restricted verification had reported CSSMERR_TP_NOT_TRUSTED; normal-context verification succeeded, including explicit certificate-bound DR checking. No trust-store or requirement weakening was applied. The installed app already reports normal **Everywhere: Overwatch** without a permission refresh during this continuation. A second actual code update with the same signer is building to verify live permission retention. The temporary metadata-only continuity variant was prepared but has not been installed; prefer the actual code update as evidence.

Actual installed screenshot/AX confirms Games/Profiles above Search games and the action footer physically separated by a divider from clipped list content. Command-F focused the search field, typing Counter reduced the rows to matching games, and Clear restored the original empty query/full list. No game launched or profile changed by these layout checks. This verifies the new UI, not original Steam Controller or game input.

Windows Steam UI inspection timed out rather than yielding an inspectable window. No process was killed. Subsequent read-only process inventory showed Wine services for Battle.net, not an active Steam Windows process. The native Mac Steam app remains running. Do not confuse a stale GUI app-inventory entry with a live Wine prefix or stop another launcher's services to make a registry change.


## Reproduced native detection failure and scoped SDL fix

A clean restart of the real shared Steam environment with saved native routing and
`v2:native` marker still gave an empty controller panel. The read-only Windows
`Tools/controller-probe/wine-enumeration.c` also reported zero attached DirectInput
and XInput controllers. Driver traces showed IOHID opening/creating 057e:2009,
followed by a Rosetta selector error or exception during registration. Turning off
msync for one temporary run did **not** restore enumeration; that comparison is
not a fix and was not saved.

Controlled temporary-prefix comparisons with the same installed Wine engine:

| Configuration | Observed enumeration |
| --- | --- |
| Fresh prefix, SDL/default path, no helper | Nintendo Switch Pro Controller, DirectInput and XInput |
| Native Nintendo Hidraw=1, no helper | Pro Controller 057e:2009, DirectInput; no XInput slot (expected native boundary) |
| Native, full current helper, no saved profile state | Zero; recursive driver failure reproduced |
| Native, helper with controller hooks disabled | Pro Controller, DirectInput |
| Native, forwarding-only controller hook | Hung; read-only stack sample shows repeated SDL_WaitEventTimeout_REAL |
| Native, full helper scoped to Wine-driver lookups | Pro Controller 057e:2009, DirectInput; no XInput slot |

The temporary scoped trace confirms **SDL itself** looks up
SDL_WaitEventTimeout before Wine's winebus.so does. The previous global dlsym
interception replaced this internal lookup too, feeding the hook into SDL's own
forwarding path. This explains why even a forwarding-only hook recursed and why a
native device could be opened but never finish registration. SDL's upstream
[dynamic API architecture](https://github.com/libsdl-org/SDL/blob/SDL2/src/dynapi/SDL_dynapi.c)
uses forwarding tables; the observed installed-library lookup and stack sample,
not that general architecture alone, establish this local recursion.

Production `nok_dlsym` now uses the actual calling image from dladdr and intercepts
only winebus.so / winebus.sys.so. Unknown callers, SDL internals and other
programs retain the original lookup. It preserves the existing controller event,
profile and sensor handling. No blanket helper removal, hidden Xbox fallback,
Wine engine replacement, permissions change or per-game workaround.

A hermetic regression builds the **actual complete helper** and fake SDL/driver
images, verifies internal lookups remain original, both supported driver names
receive forwarding hooks, unrelated callers/programs remain original, and calls
return successfully. It passes with the fix and fails with the original unscoped
hook. Physical-button, gyro and actual game consumption remain separate gates.

Only temporary diagnostic environments were stopped when their tests hung.
Battle.net and the user's game environments were not force-closed. Traces and
stack samples stay local in temporary files, outside version control; no raw
controller input or account/session logs are committed.

## Updated delivery and permission evidence

The second changed-code stable-signed build was explicitly verified running from
~/Applications/Nokcandu.app and showed normal Everywhere: Overwatch without
another Accessibility grant. An earlier first-build inspection had an extra
workspace test copy running; its app-path evidence was ambiguous, and is
superseded by the verified second-build check. Subsequent updates use the same
certificate and pass strict signature/installed-requirement continuity checks.
Only Nokcandu was closed normally for app replacement; games were preserved.

The saved native choice was reapplied through public Controllers.set after a
reliable idle check, preserving the original repair backup. WineTools.run now
centrally refreshes the saved route before its first process, matching Play;
a fake executable regression proves all native overrides exist before execution.
A live prefix remains untouched. After this addition, 176 selected controller,
profile, privacy, process and drive tests passed with normal process visibility,
zero failures/skips; nine signing tests passed. The new interposition regression
passes separately. No overall hardware-completion claim follows from these tests.

Fresh installations receive the fixed shared helper. Existing installations use
the normal owned-helper refresh; running Wine processes keep loaded old code
until their environment closes naturally. Undo uses Nokcandu's app recovery and
normal owned-helper refresh, or the preserved registry backup while fully closed
for routing migration. Do not restore an old whole registry over newer wanted
settings. No profiles, saves, game files or drive aliases were removed.


## Real installed-prefix acceptance result

The fixed full app was signed with the existing certificate, passed deep/strict
verification and the installed-identity continuity guard, and installed through
the recoverable app-only replacement. Verified the only running Nokcandu path is
~/Applications/Nokcandu.app; its helper hash matches the automatically refreshed
shared Steam helper. Normal refresh supplies the same fix centrally to owned
helpers in all applicable Wine environments. Existing running environments need
to close naturally before their loaded copy changes; Battle.net was left running.

The read-only probe in the **real shared Steam prefix**, saved As itself unchanged,
now reports **DirectInput Pro Controller, VID 057e / PID 2009, one attached;
XInput zero**. No Rosetta/driver exception was observed in this successful run.
Then the installed app's **Test Controllers** opened the same actual Windows
panel: **Pro Controller is visibly listed in Connected (DirectInput devices)**,
where the pre-fix panel had been empty. The panel is left open for user testing.
This is verified physical-device enumeration, not a claim of gyro/raw-report,
button, Steam Input mapping, Overwatch/BF1942 or all-game acceptance.

A further isolated regression using the installed fixed helper and Nintendo's
SDL/Xbox route enumerated Nintendo Switch Pro Controller in DirectInput **and**
XInput slot 0 (type 1/subtype 1). The user's real native route/profile was not
changed for this comparison. The hermetic regression also checks ordinary game
processes retain original lookups, in addition to driver-vs-SDL boundaries.

Original Steam Controller remains unresolved. Upstream SDL2's
[Steam HIDAPI source](https://github.com/libsdl-org/SDL/blob/SDL2/src/joystick/hidapi/SDL_hidapi_steam.c)
keeps its specialty driver disabled by default and documents BLE-focused report
handling. The observed 28de:1142 keyboard/vendor interfaces cannot be treated as
an IOHID joystick merely by selecting native routing. Do not enable device-mode
writes, claim receiver compatibility or replace actual identity with a synthetic
device without a controlled, supported test. No Steam controller mode/firmware,
pairing, native Steam preferences or permissions were altered.


## Preparation for user testing: held output receipt and profile headphone source

**Implemented/tested (including installed UI checks below):**
Controller Input Test (now installed and visually checked below) exposes observed held keys, mouse buttons and modifier
flags, plus an ordered bounded history of 32 control transitions with window
receipt times. Copy Test Report copies only this in-memory trial locally; no
file, network transmission, global event tap or typed-character capture. Movement
does not flood the transition history. Losing key-window focus marks observation
incomplete and clears the observed hold set, explicitly **not** claiming OS output
release. Reset starts the next trial. Core tests cover repeat/latch receipt,
independent mouse releases, unmatched release, interruption/reset, bounds and
invalid/nonmonotonic times.

The user requested headphone motion as a profile source. **Implemented/tested
(source/focused tests and installed UI):** Add Device offers an experimental
AirPods / Headphones singleton source; it has its own chip and inspector, saved
per-profile enablement, sensitivity, response, dead zone and inversion. It is not
a fabricated HID device or one of the four physical HID slots. macOS selects the
compatible headphone device; individual headphone pairing/identity is not
controlled by this API. Global settings retain status/directions, not mapping or
tuning. This supersedes the previous session-only global design.

Active-profile resolution configures headphone input **before** the unchanged
compiled-engine early return, so live head-source-only edits cannot be lost just
because Wine/C text is identical. Source/profile changes stop/restart and recenter;
tuning changes recenter without restarting the manager. No selected source,
disabled master, missing profile or unavailable Accessibility stops the source.
Existing explicit Gyro-off holds still pause/recenter both controller and headset
movement. Focus changes recenter. Headphone-only profiles use the existing mouse
output and capture policy; they do not create a Windows controller. Sensor
manager construction remains lazy until an explicitly opted-in active profile;
no existing profile is silently opted in. Source removal explicitly overrides
inherited membership; disabled mappings can remain visible in the source strip.

Optional additive `headMotion` JSON preserves old-profile decoding. The new field
participates in first-feature-save backup; existing `.pre-controller-v2` backups
are never replaced. Inherited source settings resolve through the existing stack;
child removal/disable does not modify its parent. Partial imports default safely,
nonfinite/extreme tuning is bounded before use, and round trips retain settings.
No global session settings existed on disk to migrate. Undo: remove/disable the
profile source, or restore the app-only recovery. Preserve later wanted profile
changes if using the pre-feature backup with an older app.

A focused 13-test run (before one additional membership-isolation test) passed;
the expanded final regression and packaged UI acceptance are tracked below.
Headphone hardware, permission and audio/game consumption still require the user's
acceptance; the agent does not opt a real active profile into Motion permission
merely to verify its settings UI.


Final software verification for profile-headphone/test-window preparation:
**185 selected tests passed**, zero failures/skips (including the existing privacy,
process and drive cases with normal process visibility); nine signing script
checks and the actual-helper interposition regression also passed. Packaged build
completed with the existing signer. **Not yet installed/visually accepted:** the
Mac locked during the normal quit/update preparation. No attempt to bypass the
lock, force-quit Nokcandu, grant Motion permission, or replace the running app.
The user was asked asynchronously to unlock or leave the build ready. The previous
installed native-controller fix remains installed. Continue with normal close,
continuity-guarded install, actual source-list/inspector checks using an inactive
temporary profile, and input-test receipt/focus checks when unlocked.


After the user unlocked the Mac, Nokcandu was closed normally; no running copy
remained before the continuity-guarded recoverable install. The running updated
executable is verified at ~/Applications/Nokcandu.app. **Installed UI verified:**
an unassigned temporary blank profile offered Add Device → AirPods / Headphones
(experimental), displayed the separate source chip/icon and its per-profile
switch/sliders/inversions. Disabling retained the chip; Remove removed it. The
inspector correctly identified the profile as inactive; no Motion permission was
granted/requested by activating it. The temporary test profile was deleted through
the app after testing; original profiles and Everywhere: Overwatch stayed intact.

**Installed input-test acceptance:** a CUA Space press held for approximately
200 ms produced one down/up pair; the transition history showed 0.203 seconds
between receipt. Mouse click produced one down/up pair; observed held sets were
empty after release. Moving focus to the library and back displayed the explicit
incomplete-observation warning/history entry; Reset cleared the warning and
history. Layout was visually inspected. These were ordinary UI events marked
Other source, not physical controller output or an end-to-end latency measure.
The tester is left open/reset for the user. Copy Test Report is implemented as an
explicit local clipboard action; no external transmission or persistent log.

This supersedes the temporary lock/installation-pending status above. Real headset
motion/audio, profile-switch sensor lifecycle and controller-produced latched
output remain user acceptance checks tonight. No new permissions were changed.

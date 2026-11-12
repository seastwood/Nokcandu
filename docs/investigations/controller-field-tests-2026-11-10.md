# Controller field-test follow-up — November 10, 2026

User reports and screenshots supplied after testing installed changes. Treat
Steam Input's independent mapping separately from Nokcandu's profiles. Preserve
all user profiles/settings and do not force-close games/launchers.

## Progress checklist

| Report | Current status |
| --- | --- |
| AirPods motion works | **User verified** basic motion. This supersedes earlier unverified-basic-receipt notes for the user's headset; audio/game/transport combinations remain separate. |
| Hold/layer activation for additive headphone motion | **Implemented/tested/installed.** Per-source Always / While held / In selected layer, independent of controller gyro. Installed inactive-fixture UI verified and fixture removed; real user hold/layer acceptance pending. |
| Overwatch virtual-screen movement/click mismatch | **Confirmed source defect corrected; automated/build tested and installed, actual game retest pending.** Coordinate-space validation and optional game cursor now use the Wine driver's exact conversion. |
| BF1942 aim stops at an edge | **Investigating / game retest pending.** Explicit captured Wine movement now goes through its helper's relative queue rather than postToPid events the raw-mouse hook can swallow. No automatic physical-mouse seizure or capture-rule changes. |
| Gyro moves with Nokcandu profile off | **User isolated to Steam Input:** disabling Steam Input for Pro Controller stopped it. Not claimed as a Nokcandu cleanup defect/fix. |
| Trackmania sees XInput pad but does not drive | **Pending controlled route comparison.** Physical-device discovery in Steam is not target-side XInput output/consumption. Do not change Steam's per-game/global mapping silently. |
| Pro Controller buttons rapidly change | **Implemented/tested/installed; physical mapping/game acceptance pending.** Exact USB descriptor correction eliminated the counter-driven false presses in a disposable full-SDL engine. 375 successful Windows samples, zero transitions in a repeat alongside 203 stable host reports. Physical controls/gameplay remain pending. |
| Home button remapping | Existing editor/runtime has Guide/Home input. **Research verified supported public preference API; override option/OS acceptance pending.** No Home permission prompt accepted or system behavior changed. |
| Original Steam Controller absent in Windows Steam/panel | **Still pending supported production bridge/live validation.** Earlier receiver-only bridge remains unshipped; absence in installed Wine is expected at this stage, not a completed support claim. |

## Headphone activation

Optional saved `activation`, `activationButton`, `activationLayer` fields in the
profile head source. Missing fields retain Always for existing working headset
profiles. While-held checks physical main-input state (not generated output or a
latch); the button keeps its normal mapping. Layer activation uses the engine's
actual active layer/name; missing/deleted layer fails closed. Rename/removal
updates the head-source reference, including inherited values without modifying
the parent. No virtual controller identity/extra physical device slot is created.

Only headphone output is gated. Existing controller gyro behavior is retained,
and explicit Gyro-off holds still pause both. Inactive samples discard transform
history; input/layer transitions also recenter on admission changes, even if the
pause/resume happens between headphone callbacks. First active sample emits zero,
so movement while inactive does not become a jump. Profile/master/focus/disconnect
cleanup retains existing routing guards. UI explains using Nothing for the
activation button if no other action is wanted.

Five new tests cover old JSON/defaults/round trip, physical hold and unsupported
input, real C-engine hold/toggle layer transitions with controller gyro still on,
missing/disabled/removal behavior, and no jump after inactive motion. The focused
head/gyro-pause selection passed 15 tests; expanded controller/presentation/privacy/
process/storage selection passed **195 tests**, zero failures/skips in ordinary
process context. Installed UI showed all three activation choices, L hold selector
and unset layer placeholder in an unassigned temporary profile; it was deleted.
The user's current Everywhere: Gyro-BF1942 and other profiles were left unchanged.

## Virtual-screen coordinate validation and captured Wine routing

Wine's Cocoa mouse handler emits Windows global positions using
`cgpoint_win_from_mac_global`, which applies presentation origin/scale or Retina.
The raw helper learned its event layout by comparing those coordinates to the
unconverted Mac CGEvent location. A valid scaled/origin-shifted event therefore
failed validation, leaving the relative-movement route unready. Its optional
tracked game cursor also mixed Mac coordinates with Windows event positions.

A shared patch for **Wine 10.0 and 11.0** adds two Objective-C conversion selectors
to Nokcandu's WineApplicationController. The helper asks for the driver's own
current conversions rather than guessing scale, then retains its strict layout
position check. Supported-driver events, game-cursor bounds/warps/click validation
and cursor restoration now consistently convert in the correct direction.
Drivers without the selectors retain previous behavior; nonfinite results cannot
pass validation. This is Nokcandu's own driver bridge, not a private macOS API.

The production coordinate header has a standalone Objective-C regression covering
five scales, three origins (including negative display origins), round trips,
legacy fallback, invalid conversions and reproduction of the old rejected virtual
event. Both patched drivers built successfully. Actual-helper SDL interposition
regression still passes. No claim yet that Overwatch aim/clicks are fixed in-game.

Explicit capture for a recognized Wine target previously bypassed the socket and
posted CGEvents. While armed, the helper's raw mouse hook can swallow those events
because it expects actual hardware deltas. Captured movement now prefers the
existing foreground Wine socket and requests relative output using the previously
unused mouse-message code=1. Existing kind/size are unchanged; older helpers ignore
the code and retain their ordinary movement path, rather than dropping an unknown
message. Native/streaming targets retain process-directed events. In the helper,
explicit capture can use a validated relative queue even if the game's hidden
cursor heuristic is insufficient. Default visible-cursor menus are unchanged.
Actual BF1942 edge/click/focus acceptance still needs the game.

Managed driver refresh now also requires reliable fresh idle-process evidence;
an unknown scan is not permission to replace a loaded driver. Existing stock
backups, source/installed fingerprints, version/server-request guards and normal
managed refresh remain in use. Unknown engines/manual edits are preserved; live
environments must close normally before driver/helper updates load. No game
content/save/launcher override was introduced.

Installed through same-signer, continuity-checked app recovery after normal quit.
The app includes the rebuilt drivers and matching helper. Running environments
were not force-closed. Installed metadata/migration verification is separate from
actual target-game consumption; close the game and its full launcher normally
before comparing the virtual-screen fixes.

## Pro Controller false transitions: evidence and research gate

The description-limited host observer saw 196 report 0x30/64-byte packets in one
three-second observation. A later overlapping comparison saw **200 valid full-state
reports, zero changes in the three actual button bytes**, while the nonexclusive
Windows DirectInput observer acquired successfully and read **375 samples with
601 button transitions**. No report payloads, account logs or typed text saved.
Only aggregate counts are retained in this note. Physical activity/reader state
was not formally controlled, so do not turn this into complete hardware latency
or all-mode certification.

The static 203-byte USB HID descriptor declares the first 14 bits after report ID
0x30 as buttons, then four 16-bit axes. [SDL's Switch protocol source](https://github.com/libsdl-org/SDL/blob/SDL2/src/joystick/hidapi/SDL_hidapi_switch.c)
describes full-state 0x30 as counter and battery before the three button bytes,
with four packed 12-bit axes. The observed declared button positions therefore
include the changing packet counter. This provides a concrete decoder/layout
cause for false generic Windows inputs while Steam's device-specific reader can
show correct controls. It is distinct from Steam Input intentionally mapping gyro
to mouse, which the user already isolated.

Shared header `Engine/controller-hid/pro-hid-descriptor.h` corrects only the
exact observed descriptor for **USB 057e:2009**. Other products, vendors, Bluetooth,
lengths and even one-byte descriptor changes remain untouched. It declares actual
full-state counter/battery as constants, 18 actual buttons with six reserved bits constant and packed 12-bit axes,
retaining all report byte lengths and vendor input/output report shapes. It never
changes raw packet bytes or sends device commands, preserving device-specific
protocol consumers. Native generic button indexing follows packed button usages, not
an Xbox layout; no universal game mapping is promised.

A synthetic test reproduces false old button states under 256 packet-counter
values, proves stable corrected buttons, tests axis unpacking and all match/deny
gates, and verifies other report lengths/shapes. The reproducible pinned Wine 11.0
module retains SDL (`HAVE_SDL_H=1`, verified engine soname). In a disposable engine,
its native DirectInput read succeeded for 375/375 samples with zero transitions in
the repeat alongside 203 host packets with zero actual button-bit transitions.
One preceding rebuilt-module sample and the first installed-path trial each had
one transition on button 15. Inspection showed that the first descriptor exposed
all 24 raw bits, including six fields not treated as Pro Controller buttons by
SDL's full-state decoder. It was tightened to 18 actual controls, with reserved
holes constant. Synthetic tests now prove every real control independently and
that all six reserved bits produce no buttons. Raw reports remain unchanged.
The earlier full-SDL prototype also had zero transitions; that alone was not
sufficient to certify the button declarations.
The SDL route separately enumerated an Xbox controller and XInput slot 0; this is
route availability, not proof of Trackmania input consumption or physical mapping.
Raw Steam feature/report consumption, WGI, every physical button/stick and games
remain acceptance gates. No-SDL or experimental Valve bridge builds are not used.

The app packages the correction with its source patch/header/license. Migration
recognizes only the measured stock Wine 11.0 r1 Unix module SHA-256, or its own
hash-stamped install, and requires reliable idle process inspection. A verified
original is retained before atomic replacement. Unknown modules, linked recovery
paths, damaged backups or signing failure preserve the existing driver. Existing
Windows modules, reports, routing choice, profiles and Steam settings are unchanged.
Controls exposes status plus Restore original controller input / Enable input
correction; Undo restores the first original and persists an opt-out. Five real
filesystem tests cover migration/update/idempotence/Undo, unsafe process scans,
unknown versions, manual changes, corrupt sources/backups, linked modules and
signing failure. Expanded related tests now pass **200**, zero failures/skips,
including all selected privacy tests. The first signed install and actual Controls
UI verified installed status and Undo, and Windows' panel enumerated native Pro
entries plus Xbox output; that is discovery only. Final reserved-bit install and
bounded receipt acceptance are recorded below.

## Home button and next acceptance

The existing PadGC adapter reads `buttonHome` as Guide and the editor shows Home.
Apple's public `GCControllerElement.preferredSystemGestureState` can request
`.disabled` system gestures so an app receives the element directly; the SDK
explicitly says this is a preference, not guaranteed system acceptance. The user's
Steam prompt is evidence of that OS-controlled behavior, not permission for
Nokcandu to accept a new override. Any future option must be opt-in, scoped to
active profiles, restored on deactivation/quit and tested against Steam ownership.
No such permission change was made here.

## Undo

Keep previous app recovery. Disable/remove headphone source or select Always to
restore its prior behavior; optional fields decode safely and existing first-save
backups remain untouched. Remove/disable capture rules to stop explicit capture.
Restore app/helper/owned driver together through normal managed repair/recovery,
with environments closed; preserve later desired profile edits. The Pro Controller
correction has its own per-environment Restore original controller input action;
this also prevents automatic reapplication until explicitly enabled. Local traces,
disposable runtime copies and the separate Valve experiment stay outside installed
engines. No Steam settings,
permissions, pairing, firmware, game files, saves or external-drive aliases changed.

## User clarification

The virtual-screen/invisible pointer and click-offset report is **Overwatch**.
Battlefield 1942 is a distinct rightward aim boundary, likely missing relative
capture; this remains a hypothesis until the explicit-capture game retest. Do not
collapse the two acceptance criteria into one success claim.

## Final installed acceptance

The final 18-button correction is installed in the known shared Steam Wine 11.0
engine. Actual installed app Controls UI showed Installed and Restore original
controller input, with As itself and the existing Controller as it is profile
preserved. The actual Windows panel still listed native Pro entries and Xbox
output; no Steam setting or panel checkbox was changed (closed with Cancel).
The first 24-bit declaration was superseded by the reserved-bit correction.

A final read-only probe through the **real installed engine/prefix/helper** reported
**18 buttons, four axes, 375 successful samples, zero failures, zero button
transitions and zero held buttons**. This establishes bounded idle decoding, not
physical action response or gameplay. Packaged-source hash, installed hash and
original recovery hash all verified after the final update. App deep/strict
signature and existing signing identity continuity passed, retaining the previous
app in managed recovery. No new macOS permission was requested.

The source/header synthetic regression passes with each real button independently,
reserved holes, counter variation, packed axes, match-deny gates and unchanged other
reports. Five migration/Undo tests and 200 related Swift tests pass, including
privacy. The helper interposition and mouse coordinate regressions and nine signing
checks pass. No further Swift/helper changes followed those passing checks; the
final Wine module was rebuilt and retested after its reserved-bit refinement.

BF1942 currently has physical raw mouse capture off under its existing compatibility
recommendation. Leave that user/game setting intact. Explicit **controller pointer
capture** is a separate rule; its relative Wine queue does not require enabling
physical raw capture. Retest its right-edge aim limit separately from Overwatch's
virtual-screen aim and click alignment. No game acceptance is claimed here.

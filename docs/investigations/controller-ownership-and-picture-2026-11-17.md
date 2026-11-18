# Controller ownership, 2026 picture and pad angles — November 17, 2026

## Report and scope

The user confirmed the background receiver-discovery fix eliminated the recurring stream freeze, then
reported native macOS Steam conflicting with Nokcandu's Steam Controller mode/profile. Requested policy:
Nokcandu owns controllers for its application lifetime, including in the background. This implementation
adds exclusive access for the direct Steam Controller reader, original and 2026, USB/receiver/Puck/Bluetooth.
**Other controller readers remain shared.** Seizing their devices without replacing the current
GameController input path would stop input; native Mac gamepad replacement additionally depends on Apple's
virtual-HID entitlement (see controller-capabilities.md). Do not describe this change as universal ownership.

The 2026 picture was also reported inaccurate and crowded: face buttons too far inward, pads nearly level,
gyro inside the body, stick captions over pads, and long cardinal-button captions covering nearby controls.
The supplied product image is the visual reference; exact hardware measurements are unavailable.

## Ownership implementation and limits

- `ControllerDeviceAccess` serializes open/close separately from status reads. Exclusive refusal never
  retries as shared. Successful opens are cached, refusals may retry, and release closes exactly once with
  the same flag. Status reads do not wait on blocking IOKit calls.
- `SteamControllerUSB` opens its matching manager and known controller interfaces with
  `kIOHIDOptionsTypeSeizeDevice` when requested. Discovery opens individual interfaces on the existing serial
  feature worker, preserving the fix that keeps empty-receiver probes off main. Input callbacks require
  successful interface access. Actual per-interface access, not the preference alone, drives the status UI.
- An application-lifetime listener holds the reader open even without an active profile. Turning mappings
  off no longer releases ownership when the new option is on. Switching the option stops/restores/releases
  the reader before reopening in the selected mode; held outputs are released first.
- Paused capture offers **Retry Controller Access**. Native Steam termination schedules a retry after
  750 ms. Existing verified capture is retained. Original-controller mode changes under verified exclusive
  access can be recaptured within the existing bounded retry budget; shared unknown changes remain paused.
- The existing cross-process Nokcandu lock, original controller identity checks, mode journal, conditional
  restoration, BLE framing and 2026 transient keepalive behavior remain in use. No Steam configuration,
  pairing, firmware or persistent controller mappings are overwritten; no Steam process is terminated.

Exclusive IOHID access protects event access; it is **not evidence that every Steam firmware command or
transport-specific conflict has been prevented**. Physical tests with native Steam starting/exiting,
controller sleep/reconnection and receiver slots remain pending. The earlier shutdown report is not yet a
confirmed fix. 2026 hardware/protocol acceptance also remains pending.

## Picture and angle changes

`Steam2026PictureGeometry` defines symmetric D-pad/ABXY centers, a body proportioned from the supplied photo,
and reserved annotation rectangles. `Steam2026ControllerDiagram` renders controls independently of their
captions. Y/up is above, X/left is left, B/right is right, A/down below. Stick captions are outward/below
with leader lines; pads lean inward by mirrored 10° angles, their captions stay upright below, and gyro
sits below the body. Wrapping/truncation is bounded to each lane; hovering shows the complete binding.
Live buttons, stick/pad dots, selection, layer colors and change dots still use the existing editor/tester.
Only this family uses the taller canvas; other controller diagrams retain their layout.

The physical pad tilt is presentation only. The user's **Pad angle** remains an independent setting shared
by every behavior, including circular scroll and Existing mappings. Existing mapping delivery now rotates
left touch coordinates and the right pad's stick axes in both the live engine and editor tester. The 2026
physical joystick is never rotated by the trackpad's setting. Other movement/zone paths already applied the
angle. Circular scroll measures differences between successive angles, so a constant rotation cannot alter
step count or direction; its tap/click zones still rotate. The picture shows user rotation independently of
the physical surface tilt, with upright text.

The left-pad default remains **0°**. No implicit Valve ±15° default is introduced and explicit saved angles
are preserved. This supersedes any assumption that rotation is applicable only to mouse/stick modes.

## Verification

- Debug SwiftPM app build succeeded after integration. Focused offline controller/stream suite: 139 tests,
  zero failures, including ownership refusal/retry/idempotent release, status responsiveness during blocking
  open and late-open cancellation, geometry, input rotation and existing streaming/receiver regressions.
- Geometry tests check every caption against controls/other captions and canvas containment at widths
  320, 400, 560 and 800; mirrored physical centers, pad bounds and gyro separation are checked independently.
- The actual SwiftUI diagram renderer was exported at widths 560 and 320 with deliberately long binding
  names. Both previews were visually inspected; captions wrap/truncate without covering other controls.
- Angle tests cover every behavior's straight default, explicit-value persistence, rotated tap zones,
  Existing touch/right-pad axes and physical joystick preservation, plus scroll reversal and angle wrap.
- Network-listener fixture tests are excluded because their local listener is unavailable in this execution
  environment; this is not a full-suite pass. No new physical controller or native Steam acceptance is claimed.

Signed installation remains blocked in this execution context: `build-app.sh --install` refuses to proceed
when it cannot unlock the existing signing keychain. Do not substitute ad-hoc signing or reset permissions.
The user can run the normal signed installer from their Terminal after quitting the current app.

## Fresh install, migration and Undo

The new global `controllerExclusiveOwnership` preference defaults on when absent; an explicit Off survives
updates. No profile migration or game/environment/launcher edits are needed. Existing pad angle values are
not rewritten; omitted angles resolve to zero. Diagram edits do not alter mappings or sensor coordinates.

Undo ownership in Controls → Controller Settings → Controller ownership by turning exclusive access off,
or quit Nokcandu. With Off, an active direct-reading profile can still use the existing shared reader; quit
to release that reader entirely. Set **Pad angle** to 0° to undo a chosen rotation. Reverting the app code
restores the previous picture without changing saved bindings, games, saves or launchers.

## Follow-up: pads crossed the shell cutout

The user tested the first picture and supplied a screenshot showing the rotated pads below the shell's
inner edge. The earlier preview review and canvas/caption tests missed this: containment in a bounding box
does not prove containment in a curved shell. That review is superseded for pad placement.

Rechecked the supplied front photo against the visible shell bounds (excluding shoulder protrusions).
Approximate normalized landmarks now used by the common picture geometry:

| Landmark | Horizontal shell fraction | Vertical shell fraction |
| --- | --- | --- |
| D-pad / face cluster | 0.185 / 0.815 | 0.18 |
| Left / right stick | 0.35 / 0.65 | 0.26 |
| Left / right pad | 0.305 / 0.695 | 0.55 |
| QAM | 0.5 | 0.55 |
| View / Menu | 0.32 / 0.68 | 0.087 |

The pads move up from 68% to 55% of shell height and grow from 21% to 23% of shell width. Sticks also move
up to match the photo, leaving the rotated pad edges closer below them. QAM aligns with pad centers. Upper
button/header positions and dimensions are corrected; a joined D-pad well matches the physical cross more
closely. The silhouette has fuller lower grips and a shallower, nearly flat inner cutout. Captions keep
separate lanes; the two inward-facing cardinal captions fit above the sticks without relocating hardware.

`Steam2026PictureGeometry.shellPath` is now used by both the SwiftUI shape and containment tests. A new test
samples all four expanded rotated-pad edges (4 scaled points of clearance) at widths 320/400/560/800 and
checks separation from the sticks/cutout and alignment with QAM. The prior annotation-overlap tests still
apply. This is a presentation-only correction for fresh/existing profiles: no migration, mapping, pad-angle,
ownership or calibration changes. Undo is reverting the picture implementation; user data is unchanged.

Follow-up validation: the debug app build and all four focused picture tests passed. Refreshed SwiftUI
previews at 320 and 560 points were inspected; pads remain above the cutout and the annotation lanes stay
clear with long names. Installed-app acceptance of this refinement is pending the user’s signed rebuild.

## 0.14.4 release preparation

The user accepted the picture refinement and requested commit/push/release as 0.14.4. `VERSION` and
`release-notes/v0.14.4.md` are prepared. Final focused validation passed **140 tests, zero failures**, with
the same three unavailable network-listener fixture classes excluded; `git diff --check` is clean. The
existing tag workflow checks VERSION, builds/tests/packages and signs, then publishes the release and DMG
with these notes. No workflow/signing changes are required.

Commit and publication could not be completed in this execution context: staging was refused because
`.git/index.lock` cannot be created, and remote GitHub access failed DNS resolution. No commit or tag was
created and no push/release occurred. Local handoff exports and conversation files are outside the intended
commit paths. Finish the normal commit, main push and matching `v0.14.4` tag push from an authorized Terminal;
release build/publication success remains unverified until the tag workflow finishes.

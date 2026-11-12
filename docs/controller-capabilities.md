# Controller capability and validation matrix

November 10, 2026. A channel exposed by an API is not verified game support. Update a row only with observed hardware/connection and target evidence. Source research and architecture are in the [investigation](investigations/controller-overhaul-2026-11-10.md).

| Device | Connection | Current path / evidence | Remaining verification |
| --- | --- | --- | --- |
| Original Steam Controller (2015) | Micro-USB | No dedicated protocol reader added; generic HID recognition is insufficient for its full feature set | Physical discovery, report format/lizard/Steam mode, both trackpads, rear grips, stick/triggers and motion; Steam and streaming comparison |
| Original Steam Controller (2015) | Original wireless receiver | Receiver-off 28DE:1142 inventory verified; research-only vendor HID bridge exposes four slots to Windows, not shipped | Controller-on Windows Steam discovery/feature transfers, reports, both pads/grips/motion and ownership |
| Original Steam Controller (2015) | Bluetooth on supported firmware | Not tested; availability firmware-dependent | Firmware/configuration and report channels, Steam mode transition |
| Nintendo Switch Pro Controller | Session connection not independently identified | GUI GameController probe observed vendor “Pro Controller”, extended gamepad and motion object, continuous motion callbacks while Steam/Nokcandu ran | Confirm exact model/transport; nonzero stick/gyro values, transformed output, duplicates, capture and target acceptance |
| Nintendo Switch 2 Pro | USB / Bluetooth separately | No physical test; existing adapters preserved | OS exposure, capabilities, reports and known-good-controller regression |
| 8BitDo models, including Ultimate 2C | Each supported USB/receiver/Bluetooth and device mode separately | No physical test; generic HID/GameController paths only where exposed | Exact model/VID/PID/mode, layout/triggers/motion, duplicates and Steam coexistence. Firmware toolkit is model-specific context, not a support guarantee |
| Xbox | USB / receiver / Bluetooth separately | Existing adapters preserved; no new connection certification | Model-specific visibility, trigger/axis and disconnect regressions |
| PlayStation | USB / Bluetooth separately | Existing adapters/touch/tilt paths retained; engine policies tested, hardware not tested | Touch/click/motion, output/Steam and disconnect regressions |
| Compatible AirPods/headphones | Documented macOS headphone motion API | Experimental capability-gated profile source through Add Device; existing profiles opted out; math/storage tested | Exact model, permission, nonzero yaw/pitch, recenter, simultaneous controller and uninterrupted audio |

## Output boundaries

| Output / target | Status |
| --- | --- |
| macOS generated keyboard/mouse | Event construction and source/cleanup tests passed. Native isolated test window received ordinary UI clicks/key events; actual controller-generated receipt remains a user test |
| Wine controller route | Existing SDL/Xbox-style profile output, new value-routing policies tested in C. Not a newly created virtual device or guaranteed original-device identity |
| Fixed-anchor mapped mouse to native app | Implemented opt-in process routing; target acceptance pending |
| Fixed-anchor mapped mouse to Wine game | Implemented; Overwatch/BF1942 before/after acceptance pending |
| Fixed-anchor mapped mouse to Moonlight/VoidLink/other streaming client | Selectable direct target; actual acceptance and duplicate-input checks pending |
| macOS physical-device suppression / physical mouse seizure | Unavailable in this implementation; not represented as supported |
| New Xbox-/DS4-/Nintendo-like virtual controller | No backend. Feasibility gate not passed: authorized signed API/deployment, actual target identity, latency and safe fallback must be tested first |

The virtual-device candidate matrix remains **not run** for native monitor/game, Nokcandu Wine title and external streaming client. CoreHID SDK presence on newer macOS, or a logical layout preset, does not satisfy the target-recognition gate. No unsupported identity is offered in the UI. No controller firmware, pairing, Steam device ownership or system entitlements were modified.

## Repeatable observation

Use Settings → General → Controller diagnostics for receipt age, readers, focus/profile/capture and Steam presence. Keep connection/model and test conditions with each result. The temporary `Tools/controller-probe` sources observe callbacks without injecting events or changing sensor activation; command-line execution observed no devices while the GUI context did, so do not treat CLI absence as incompatible hardware. The later GUI engine probe emitted no mouse output while idle; the user was unable to rotate the controller for an active check. No real-game compatibility conclusion follows from these idle observations.


November 10 native-routing update: the installed shared Steam Wine environment and
its actual Windows panel now enumerate the connected Pro Controller as native
Nintendo 057e:2009 through DirectInput. The shared SDL lookup recursion and routing
precedence/registry defects are fixed. An isolated SDL/Xbox comparison also sees
XInput slot 0. This supersedes earlier enumeration-pending notes for this specific
Pro Controller/engine observation; button, motion, game and other transport
certification remain pending. Original Steam Controller vendor/keyboard interfaces
still lack verified Windows enumeration. [Controlled evidence](investigations/signing-routing-sidebar-drives-2026-11-10.md#real-installed-prefix-acceptance-result).

## USB Pro descriptor acceptance (November 10 follow-up)

An exact USB 057e:2009 descriptor was independently inspected. Its full-state
counter/battery bytes were mislabeled as buttons, explaining stable host fields
versus hundreds of generic Windows button transitions. The shared Wine 11.0 r1
correction preserves raw packets and exposes the actual 18 buttons (reserved
bits constant) plus packed 12-bit sticks. It has bounded native DirectInput idle
acceptance and migration/Undo tests; physical button/stick calibration, Steam
protocol use, WGI, games and Bluetooth remain unverified. This supersedes only
those earlier generic connection/idle-decoding gaps, not gameplay acceptance.
[Evidence and current status](investigations/controller-field-tests-2026-11-10.md).

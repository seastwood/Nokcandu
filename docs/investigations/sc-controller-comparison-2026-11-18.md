# sc-controller remapping comparison

Initial research, November 18, 2026. Inspected the linked C0rn3j/sc-controller main README and rendered
action documentation in GitHub. Main showed commit `0f65285` during inspection. Web search primarily
returned kozec's upstream and Patola's separate fork; those results should not be treated as the current
C0rn3j feature/support matrix. The exact linked README now describes GTK 4, not GTK 3.

**Subsequent implementation:** all five candidates below now have opt-in implementations in Nokcandu.
The table records the pre-change comparison; see [advanced controller remapping](../advanced-controller-remapping.md)
for current setup, precise scope, verification and unresolved physical/emulator acceptance.

Primary sources:

- https://github.com/C0rn3j/sc-controller
- https://github.com/C0rn3j/sc-controller/blob/main/docs/actions.md

## Additions worth evaluating

| Capability documented by sc-controller | Current Nokcandu comparison | Practical value |
| --- | --- | --- |
| `area`, `winarea`, `relarea`, `relwinarea` | Trackpad motion is relative; fixed-anchor mouse capture is not an absolute touchpad-to-region mapping | Bind a pad to a whole game window, inventory or minimap. Requires explicit Mac/Wine/stream coordinate handling. |
| `gestures` with recorded directional strokes and recognition tolerance | Pads have taps, click zones, direction bindings and layers; no comparable drawn-gesture recognizer found | Add several commands without consuming more physical buttons. Must gate recognition to avoid accidental movement/actions. |
| `hipfire` trigger arbitration, including timed exclusive and retrigger modes | Soft/full trigger thresholds exist; no equivalent timed partial-versus-full arbitration found | A fast full pull can bypass the soft-pull action; a slow pull can aim first. Keep trigger thresholds and old profile behavior unchanged by default. |
| Horizontal, grid and button-selected quick menus | Nokcandu has radial menus and an on-screen keyboard | Alternate layouts/selection modes suit inventory slots and shortcuts. Preserve existing radial-menu definitions. |
| `cemuhook` motion provider | Gyro mapping and stream motion exist; no DSU/CemuHook server found | Provide raw motion to compatible emulators rather than translating it into mouse or stick input. Emulator support and coordinate/timestamp behavior need validation. |

Nokcandu already implements much of the broad feature list: gyro, trackball, macros, sequences, rapid
fire, layers, radial menus, an on-screen keyboard, haptics, app rules and direct Steam Controller input.
These should not be described as newly missing features. Sc-controller also documents absolute gyro
mapping; Nokcandu's existing tilt/gyro handling needs a more detailed comparison before claiming a gap.

My suggested priority is absolute mouse regions, drawn gestures, then trigger arbitration. These are
usability recommendations from comparing the documentation and local code, not measured performance
improvements. The README says macOS-port feasibility is still under evaluation; its Linux virtual-input
backend is not a solution to Nokcandu's Apple virtual-device entitlement boundary. No external source
code was copied, integrated, installed or executed. This research does not certify any platform port.

# Receipt-only controller probes

These temporary diagnostics are independent of Nokcandu's library/startup. They do not inject events, pair/discover devices, activate sensors, change device reports or write profiles. Keep output local; do not commit raw user sessions.

`main.swift` runs for three seconds in command-line context. `window.swift` uses GUI AppKit discovery/receipt and feeds the shared C engine into a counting sink, never an output backend. The GUI probe includes a normal Quit menu. Close it after testing.

A command-line absence is not evidence of incompatible hardware. In this session the command-line context saw zero devices while the GUI received Pro Controller motion callbacks. Idle callbacks did not yield engine mouse movement. Test rotation only when the user can safely move the controller; no nonzero movement was verified here.

Build the CLI with `xcrun swiftc -module-cache-path /tmp/nokcandu-swift-cache Tools/controller-probe/main.swift -framework AppKit -framework GameController -o /tmp/nokcandu-controller-receipt`, then run that executable.

For the GUI, compile `Sources/NokcanduPadEngine/padengine.c` into a temporary object with its `include` directory, and compile `window.swift` with `-import-objc-header Sources/NokcanduPadEngine/include/padengine.h`, the object, AppKit and GameController. Place the result inside a temporary `.app` with executable `probe`, a unique diagnostic bundle identifier and `CFBundlePackageType=APPL`. Do not install it or reuse Nokcandu's production bundle identifier. Launch explicitly by full path and verify it quits. The GUI engine uses a disposable test profile rather than reading the user's profiles.

For ordinary user testing, prefer Nokcandu's **Help → Controller Input Test** and the [testing guide](../../docs/controller-overhaul-testing.md). A receipt-only probe and a target-side input test answer different questions; neither certifies game input latency by itself.

`benchmark.c` times synthetic shared-engine gyro/tick, compatible binding updates and engine rebuilds with counting-only sinks. Build with `xcrun clang -O2 -ISources/NokcanduPadEngine/include Tools/controller-probe/benchmark.c Sources/NokcanduPadEngine/padengine.c -o /tmp/nokcandu-controller-benchmark`, then run it. Add `-fsanitize=address,undefined` for a memory/undefined-behavior smoke run; sanitized timings are not comparable to optimized ones. This tool neither waits at physical input cadence nor measures UI, persistence, OS injection, device transport or game response. Results are local observations, not performance guarantees.

`wine-enumeration.c` checks the Windows API boundary without acquiring a controller,
reading button/axis states, sending HID commands or rumbling. It lists attached
DirectInput devices after a three-second settling interval, and XInput capabilities
for the four standard slots. Exit 0 means at least one of these APIs enumerated a
device; exit 1 means neither did; exit 2 means DirectInput initialization/enumeration
failed. This is detection evidence, not a button/motion or game-compatibility test.
Build with a Windows-targeting C compiler, linking `dinput8` and `dxguid`, and run
through the selected game's existing Wine environment with its normal launch
variables. Native Nintendo routing is expected to enumerate in DirectInput and
may legitimately have no XInput slot. The probe performs no networking.

`python3 Tests/BuildScripts/test_pad_interposition.py` builds the actual helper
against fake SDL/Wine driver images. It verifies SDL's own symbol lookups and
unrelated programs stay unmodified, both Wine driver names receive forwarding
hooks, and forwarded calls finish. No physical controller/Wine or privacy grant is
needed. The unscoped pre-fix hook fails this regression.

`steam-inventory.swift` reads only Valve HID descriptions without opening devices,
printing serials, reading reports or sending feature requests. Build with
`xcrun swiftc -module-cache-path /tmp/nokcandu-swift-cache Tools/controller-probe/steam-inventory.swift -framework IOKit -o /tmp/nokcandu-steam-inventory`.
The original 28DE:1142 dongle can be present while every controller is off.
Four vendor interfaces are receiver slots, not four connected controllers.

The Windows enumeration probe also lists present Valve HID interface VID/PIDs
through SetupAPI **without opening them**. Add `setupapi` and `hid` to its link
libraries alongside `dinput8`/`dxguid`. Zero gamepads/exit 1 can coexist with
successfully enumerated raw receiver interfaces: inspect the separate HID count.
No paths, serials, button states or raw HID data are printed by this probe.

`steam-vendor-hid.patch` is a **research-only Wine 11 IOHID filter spike**, not
packaged or installed by Nokcandu. It admits only 28DE:1102/1142, vendor page
FF00/usage 1, with `NOKCANDU_EXPERIMENTAL_STEAM_VENDOR_HID=1`. Keyboard/mouse
interfaces, other Valve products and default-off behavior retain the old filter.
It has only passed receiver-off enumeration in a temporary engine/prefix. Do not
apply it to installed game engines: feature transactions, powered-on reports,
Windows Steam discovery, reconnection and coexistence are untested. The temporary
research build was configured without SDL; it is unsuitable for deployment or
regression comparison of normal Xbox/profile behavior. See the
[Steam Controller investigation](../../docs/investigations/steam-controller-2015-2026-11-10.md).

`controller-inventory.swift` reads controller HID descriptions and parent class names only. `sdl-inventory.m` passively enumerates the selected runtime without opening controllers; use it to distinguish the old unversioned SDL from the stock versioned compatibility runtime. Normal Mac device visibility is required.

`wine-all-inputs.c` acquires up to sixteen DirectInput devices nonexclusively and counts successful samples, button transitions and axis changes for 1–300 seconds (default 180). It sends no rumble or input injection. Build with a Windows C compiler and `-ldinput8 -ldxguid`. Match each reported product to deliberately operated hardware; a transition count alone cannot prove the correct mapping, idle stability or game receipt. Use a disposable prefix for driver comparisons; stop only that prefix's server before changing the temporary module.

`steam-settings-receipt.swift` queries only five selected original wired-controller settings by default. `--test-mode` explicitly exercises a two-second volatile takeover and exact restoration/read-back; it changes trackpad/lizard/IMU mode, never mappings, pairing, firmware or factory settings. Keep Steam and other controller owners closed for this controlled test. It is a feasibility diagnostic, not an installed controller owner or keyboard-duplication certificate.

`steam-wireless-receipt.swift` queries the original 1142 receiver's selected controller settings by default. Build with `SteamControllerMode.swift`, `SteamControllerTransport.swift` and `SteamControllerIdentity.swift` plus IOKit. `--test-mode` explicitly captures/restores volatile mode for two seconds with read-back; `--observe` extends that to three minutes and counts full-state/button-contact/motion receipt without injecting input. Keep other owners closed. No pairing or firmware commands are sent. See the [wireless investigation](../../docs/investigations/steam-wireless-profiles-2026-11-11.md).

The wireless receipt also checks two matching remote identity replies without printing the unit string. `--simulate-mode-loss` is a controlled fault test: it requires a matching identity recovery receipt and current captured settings, restores that measured baseline, then waits four seconds for the app to recapture. On failure it attempts to restore the pretrial captured state. `--restore-observed-original` is a narrowly guarded repair for this investigation's previously measured 3/0/1/0/2 baseline; it is not a general reset command and must not be used for an unknown controller. Do not run observation probes concurrently with final typing/haptic acceptance checks.

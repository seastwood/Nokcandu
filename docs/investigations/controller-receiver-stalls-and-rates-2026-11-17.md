# Receiver stalls and controller report rates — November 17, 2026

## Evidence and scope

Continuation of the supplied Claude conversation, after 0.14.3. The user observed the original Steam
Controller stalling and recovering over its dongle while streaming. The supplied log summary records
repeated input-paused/reacquire transitions and missing settings replies. Raw logs were not independently
re-read here. Neither that summary nor source inspection establishes a faulty radio or dongle.

Source inspection confirms two avoidable interruptions in the shared original-controller reader:

- A 0.3-second receiver input gap released outputs **and** discarded capture. Reacquisition runs scans and
  feature transactions instead of accepting the next input on the verified channel immediately.
- Three unanswered settings queries discarded capture even when fresh input continued to arrive.

The earlier policy treated short gaps as lost ownership. Increasing the hold timeout would keep
movement/buttons stuck longer; this change retains the existing 0.3-second release deadline instead.

## Implementation

`SteamControllerUSB.expire()` resets held state and haptic accumulation but keeps the original receiver's
verified channel/lease. The next input resumes immediately, including a repeated sequence number because
the stream decoder was reset. Disconnect notifications, removal, actual settings mismatches and bounded
recapture of the measured original mode retain their prior behavior. Three consecutive unanswered settings
checks still reacquire a silent remote if its disconnect notification was missed. Fresh input prevents
missing feature replies alone from causing a retake. Health resets on channel acquisition and successful
settings reads. Bluetooth uses its existing 1-second freshness allowance; wired behavior and the 2026
controller's timeout policy are preserved. This affects desktop profiles and streams, without game overrides.

## Polling-rate audit

| Reader | Input delivery | App-imposed polling delay |
| --- | --- | --- |
| Original/2026 Steam Controller | IOHID input-report callbacks; BLE state assembled from segments | None in normal receipt |
| Switch 2, report-driven pads, GameCube adapter | IOHID input-report callbacks | None in normal receipt |
| Xbox USB/360 receiver | Blocking interrupt read, immediately reissued on a device thread | No polling sleep; unchanged state publication is suppressed |
| macOS GameController | Changed-value and motion callbacks | No polling timer; change frequency is not hardware report frequency |
| Generic HID/profile devices | IOHID input-value callbacks | Change events, not one callback per hardware report |

The 4 ms `DesktopPad` timer advances timed mapping actions, stick movement and macros. Physical reports
and gyro processing happen on arrival; it does not cap receipt at 250 Hz. The 100 ms Steam timer checks
staleness/capture; it does not poll input at 10 Hz. Feature-reply retries have transport-specific sleeps,
separate from normal input receipt. HID/GameController processing still shares the UI's main thread, and
initial Steam capture uses synchronous feature operations. This audit does not establish zero queue delay
or maximum hardware performance, and does not move those operations to a separate input executor.

Controls → Controller Settings → Controller diagnostics → Show session input diagnostics now shows
per-reader arrival rates, callback totals and largest gaps. The rolling rate uses at most 256 arrivals;
after one second without a callback it shows zero. Storage is capped at 32 rows. Reset clears measurements;
disabling diagnostics discards them. No raw reports or device identifiers are saved to disk.
Xbox measurements are taken before change suppression and dispatch to main; raw HID measurements are at
callback entry. GameController rows cover profile and direct-stream handlers. Raw HID/USB reports include
status traffic; BLE can split a state across reports. Generic HID and GameController changes can be sparse
while idle. Move sticks/gyro when comparing. These are app delivery rates, not certified hardware polling
rates or screen latency. No firmware, USB overclock or radio interval was changed speculatively.

## Validation and limits

Focused suite: **38 tests passed** (Steam Controller, callback-rate statistics, timing statistics and Wi-Fi
helper syntax). New tests cover gap/resume with the same counter, live input with missing feature replies,
silent-remote recovery, heartbeat rejection, health reset, 125/250/1000/8000 callbacks per second, ring wrap,
idle/gaps/invalid times, opt-in bounded storage and concurrent independent readers.

Full-suite attempts in this restricted execution context recorded the same 48 failed test cases in changed
sources and a separate untouched HEAD export before ceasing progress. Many failures explicitly refuse
mutations because process enumeration is unavailable and running status is unknown. These incomplete runs
are not a passing suite or proof of every baseline equivalence. The debug app and tests compiled successfully.
Optimized Swift compilation and linking also produced the executable; the release build then failed at
`GenerateDSYMFile` with “Operation not permitted”. This is not a completed release/package verification.
Running `dsymutil` directly succeeded, but retrying the release build still failed when its build service
launched that same debug-symbol task. Treat this as an execution-context limitation, not a successful build.

Signed app packaging stopped before replacing the app because the configured signing keychain cannot be
unlocked in this execution context. The signing guard was preserved; no ad-hoc fallback or keychain change.
No update was installed. Physical playtesting, measured hardware rates and stream comparisons remain pending.

The existing uncommitted streaming Wi-Fi changes were preserved: streaming contributes to the playing
flag and requests it at stream start. That separate change was already installed in the supplied Claude
conversation; no new physical AWDL or network-latency conclusion is claimed here.

## Migration, Undo and hardware acceptance

New and existing installs use the same reader policy on their next launch. No profiles, calibration, game
content, saves, launchers, pairing or stored mode receipts are migrated or rewritten. Existing startup mode
recovery and the ownership lock remain in place. Undo: rebuild the previous source; diagnostics can also be
turned off independently without migration.

Stream over the original receiver, observe rate/gaps during motion, and correlate felt stalls with
“waiting for input” versus actual capture-loss messages. Repeat off/on, disconnect and USB/BLE comparisons;
verify held buttons release on genuine silence and original desktop mode is restored after app quit.
Radio gaps can still occur; the fix prevents unnecessary software recapture from extending them.

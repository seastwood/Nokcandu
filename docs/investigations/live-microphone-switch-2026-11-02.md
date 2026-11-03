# Live per-game microphone control (2026-11-02)

## Scope and implementation

Shared Wine infrastructure, including custom games, recipe installations and Steam/Battle.net/EA/Ubisoft shortcuts. Native Mac games are outside this helper's scope. The switch updates only the saved microphone field or client consent flag, macOS purpose metadata and prefix/program policy. It does not regenerate a running launcher, close games, replace game content or change the Mac's selected audio devices. Unknown JSON fields and the existing launcher hash are preserved. Profiles continue to carry the existing microphone preference; they never carry macOS consent.

Wine caches its audio endpoint list at process startup. Hiding all inputs initially therefore prevents later enabling in the same process. A generated `microphone-live` marker enables read-only modern Core Audio discovery while retaining the legacy HAL query guard, absent usage declaration when Off, and capture EnableIO denial. A disabled game can list a microphone name, but cannot open it. Old helpers ignore the marker and retain their previous behavior.

The audio helper polls the per-program policy every 250 ms off the realtime thread. Off stops active capture units; On resumes only units still requested by the game. Explicit game Stop/Dispose prevents resurrection. Capture Render uses atomic state to return silence while blocked, with no file I/O or locks in that callback. Output units are untouched. Unit mutations and disposal are serialized; unit-list locks are not held across HAL Stop/Start. Input-device following is enabled when input first becomes allowed. Exhausted tracking fails capture setup closed.

## Verified evidence

- Hardware-free tests exercise active On → Off → On, capture Render silencing without forwarding, unchanged output Render, explicit stop/dispose, startup input denial and legacy query guards.
- A managed scratch-prefix diagnostic ran one unchanged Windows process (Windows PID 224). It started Off with four discoverable inputs and repeated `waveInOpen=1` failures. Changing the actual saved setting to On produced `open=0` and nonzero levels in 16,000-sample buffers. Off produced timeout 258, zero delivered samples and zero reported peak. On resumed the original pending stream and nonzero sample levels without process replacement. Final Off again stopped delivery; the diagnostic was stopped. Samples lived only in memory and no recording was saved. The diagnostic apps, scratch prefix and only their test history/journal were removed after validation.
- A fresh-identity native playback-only check with the complete live helper and Microphone Off reported input device discovery, playback unit creation 0 and initialization 0, with no visible microphone permission dialog. It never opened input or queued audio. This establishes playback initialization, not an audible-gameplay test.
- The final complete suite passed 244 tests with ten optional skips and zero failures, including the input-listener/tracking-capacity refinements. The seven microphone tests were re-run successfully after adding explicit capture-role removal when input is disabled.

A second fresh-identity test exposed a first-use limitation: starting Off and adding the usage declaration mid-session allowed stream setup but delivered silent samples, and TCC reported automatic refusal for missing purpose metadata cached at startup. No user permission prompt was shown, so a planned local approval was unnecessary. Do not treat stream-open success or silent buffers as proof of authorized capture. First-time authorization may require one close/reopen with On; subsequent switching with permission granted works live. This comparison did not change TCC decisions or global settings. Some games independently cache failed microphone opens or do not retry voice chat; they may need their own voice-chat setting refreshed. Existing explicit macOS denial requires the user to change Privacy & Security. No consent database is modified.

## Fresh installs, migration and Undo

Refresh writes the live-mode marker and installs the shared helper through the existing migration path. A process already using an older helper needs one normal close/reopen to load the update; subsequent switch changes are live. Explicit saved preferences and manual launchers are preserved. Finder/Dock launches use the saved policy rather than stale generated environment flags. New installs use the same shared code.

Turning the switch back restores the previous preference. JSON setting changes use the existing journal; native-entry Undo retains the current microphone policy. Removing the generated live marker restores hidden input discovery on the next process start. Reverting the helper implementation requires closing/reopening the game. None of these actions revoke or grant OS consent, alter saves or replace proprietary runtime/game files.

## Raw mouse permission explanation

The Mouse section explains that macOS Input Monitoring/“Keystroke Receiving” is used for direct mouse movement, and the Nokcandu mouse helper does not read typed keys. The helper matches mouse/pointer devices and relative X/Y elements. A GameController fallback remains available without the direct HID path. This is in-app copy; the system dialog wording is unchanged. Apple's [CGRequestListenEventAccess](https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess()) API has no custom-text argument; [Input Monitoring settings](https://support.apple.com/guide/mac-help/control-access-to-input-monitoring-on-mac-mchl4cedafb6/mac) describe the broader system permission.

Packaging: a signed development build is prepared. Installing/restarting Nokcandu was deferred because the user’s Battlefield 2 installation was at its interactive play-test step. The existing game session was left intact.

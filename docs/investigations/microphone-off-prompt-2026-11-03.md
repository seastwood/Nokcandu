# Microphone-Off permission prompt — still open in 0.12.4

## Release decision

**November 4 update:** 0.12.4 was released for the profile/component fixes, with this microphone issue explicitly disclosed as still unresolved. The former 0.12.4 target was not met; no new fix version is promised. The findings and required verification below remain the next work. See the [current handoff](../handoffs/development-handoff-2026-11-04.md).

On 2026-11-03 the user authorized releasing 0.12.3 with this issue explicitly deferred to 0.12.4. It is not fixed in 0.12.3. The release notes identify the limitation instead of claiming that Off universally prevents prompts.

## Required behavior

Off must prevent both microphone permission dialogs and captured input. On must permit input and normal local macOS consent when needed. The switch must retain supported live On/Off behavior. Apply the correction centrally across applicable game types, with safe migration/Repair and profile settings preserved.

## Verified evidence

After Falconeer's Wine 10 → 11 upgrade was corrected, the user confirmed it ran but reported a microphone prompt while its switch was Off. Saved policy was Off, both app/wrapper usage declarations were absent, and the installed audio helper matched the current build. A debugger check in the running game returned a blocked microphone decision. A disposable Wine probe exposed cached input endpoints, opened output without queued sound buffers, and refused input opening; no recording was started or saved.

Timestamped tracing placed a macOS consent request inside AudioComponentInstanceNew, before the later input-enable call was refused. System logs contained real consent-request attempts; a quiet diagnostic window did not prove no request occurred. Fresh diagnostic app identities could refuse those requests silently for a missing usage declaration, while the actual game used a path-based launcher identity and displayed a prompt. The exact reason for this attribution difference remains unresolved.

The user allowed the original game's prompt. No macOS consent database or global audio settings were reset. That allowance can mask future dialogs on the same identity, so final verification needs a fresh controlled identity as well as existing-installation tests.

## Comparisons worth avoiding

Rejecting null audio-unit format queries did not eliminate requests. Narrowly refusing input preferred-layout queries, supplying channel-count-derived layout metadata, distinguishing system callers from client discovery, and substituting an output-only component while Off did not establish a working correction. Strict discovery hid input endpoints but still produced consent-request activity in the measured setup. These comparisons were isolated temporary binaries, not product changes.

A temporary rename of Falconeer's native entry also still prompted. After the user denied that prompt and closed the game, the original launcher metadata/ownership record and executable path were restored, with later settings preserved. Engine selection and its Wine 10 rollback copy were retained. The rename is not a fix and is not included in 0.12.3.

Further app-identity/registration comparisons were prepared, but no general solution has been verified. Do not promote those hypotheses into a claim of cause or migration behavior.

## Remaining verification and Undo

Reproduce against fresh identities without relying on a prior Allow/Deny to hide the dialog. Verify Off never prompts or captures, playback still works, explicit On receives actual samples, and live On → Off → On still works. Include shared store hosts, private installations, Finder/Dock starts, and engine replacement/Repair paths where applicable. Keep raw audio, account/session traces, binaries and machine-specific test backups outside the repository.

No new microphone correction is installed as part of this investigation. Normal saved microphone choices and existing app/engine rollback remain available; they do not reset OS consent. Detailed temporary experiment logs are local diagnostics, not shipping artifacts.

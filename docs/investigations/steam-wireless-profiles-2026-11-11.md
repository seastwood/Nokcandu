# Original Steam Controller receiver profiles — November 11, 2026

## Scope and checklist

The user requested original dongle wireless support, then a slight upward adjustment of the Steam diagram controls. This increment extends Nokcandu's existing explicit Steam Controller profile source from the USB cable to the original 2.4 GHz receiver. It does not implement BLE, pairing/firmware management, multiple simultaneously mapped Steam Controllers or proprietary Windows Steam discovery.

| Requirement | Status / evidence |
| --- | --- |
| Identify original receiver channels safely | Implemented/tested: only Valve 28de:1142 FF00:1 interfaces 1–4; wired 1102 interface 2 retained. Keyboard interface 0, other vendors, BLE and Deck rejected. |
| Distinguish a dongle from an awake controller | Implemented: a slot needs complete selected-settings response and verified capture before selection. Full-state receipt separately controls receiving-input status. Four interfaces are not four controllers. |
| Verify radio mode transactions | Actual slot 1 responded with 3/0/1/0/2. Two-second trial applied capture, verified it, restored original and verified it. No reset, digital mapping clear, pairing, factory or firmware commands. |
| Wireless physical input receipt | Actual three-minute capture: 17,969 full packets; 17,760 with nonzero gyro bytes; A, left/right rear grips and left/right pad contact seen during user-directed operation. Original mode restored with matching read-back. This proves transport/observed controls, not every axis direction or game acceptance. |
| Reuse profiles, pad behaviors and tuning | Implemented; same `steamUSB` encoded source value retained for compatibility, UI renamed USB / receiver. Both transports use existing full-state decoder, trackpad/trackball, touch gyro, X/Y and haptic settings. Installed acceptance pending below. |
| Release on radio disconnect / stale input | Implemented: active slot disconnect clears lease, output gate and all listeners; missing full reports releases held actions after existing 0.3 s timeout. Receiver continues listening and scans idle slots every two seconds. Actual off/on/reconnect acceptance pending. |
| Radio haptics without blocking cursor delivery | Implemented: one bounded in-flight receiver burst on a serial feature queue, cancellable per radio session; normal mode restoration waits for queued output. Physical wireless haptic feel pending. |
| Slightly raise Steam diagram controls | Implemented Steam-only 6% body-height upward shift for on-body controls; other families and shoulder/trigger positions unchanged. Installed visual acceptance pending. |
| Regression checks | 620 Swift tests, zero failures, 19 optional integration skips, including privacy tests. Four new transport tests cover interface filtering, bounded radio retries, event bounds/input reset and cancelled output sessions. Final build/install/UI below. |

## Research and implementation decisions

Primary protocol source: [Valve/SDL Steam driver](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_steam.c), [constants](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/steam/controller_constants.h). Receiver interfaces 1–4 carry independent controller slots. Cable and receiver full-state packets share the existing report format; BLE does not. Radio feature requests can transiently report failure while pending, so the transport retries the identical request up to fifty attempts with 0.5 ms between failures. The cable keeps its prior single-send behavior. No pairing-enable request is sent.

Only one responsive controller is selected. Initial selection prefers cable, then stable receiver interface identity; a live selected controller is never silently replaced by another slot. Each channel owns its own report buffer and callback context. All receiver channels keep listening; a radio connect event or bounded idle scan can discover a controller after the app starts. Inactive slots cannot refresh the selected stream's timeout or map their input.

Receiver haptics are queued away from the main input loop, with at most one in flight. Cancelled connection gates prevent further attempts after a disconnect/stop, and late completion cannot mark a newer session failed. Features are serialized before selection/restoration. Existing ownership lock still excludes competing updated app readers.

The first installed receiver candidate kept mode leases in memory to avoid replaying a receiver-slot lease into a different controller. **That was incomplete:** after a user off/wake test, a normal app shutdown left 7/7/0/24/2 rather than the observed original 3/0/1/0/2. Mode state can survive a remote power cycle, so earlier advice that a power cycle alone recovers desktop mode is withdrawn. The current follow-up queries the remote controller's unit-string attribute and retains only a SHA-256 digest, with a recovery receipt keyed by that digest. Reconnection/crash recovery reuses the observed original only for the same digest and still-matching captured mode; another owner's changed mode is preserved as a new baseline. Normal restoration checks the remote identity again before writing. The wire transport's existing registry-specific recovery is unchanged. This follow-up is implemented/software tested; installed off/wake/restore acceptance remains below.

A bounded local probe verified two matching identity replies without printing the serial. An empty successful 0xae reply was not an identity: the working query uses a one-byte attribute payload and waits 3 ms between bounded reads. The already measured original settings for the sole test controller were restored only after its stable identity and exact captured settings were verified; read-back matched. No generic factory/default reset was used. Protocol source: [Linux's original Steam controller identity exchange](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-steam.c), alongside Valve's feature header/string layout.

## Fresh installation, migration and Undo

The existing source raw value `steamUSB` and all profile fields remain valid; no profile/game/runtime rewrite is needed. Existing profiles selecting this source can use the receiver automatically after the cable disconnects. Unselected/automatic profiles are not opted in. Native wireless passthrough to Windows Steam is still unverified; the new profile source supplies Nokcandu's existing keyboard/mouse mappings and does not claim original-device emulation.

Undo: turn all controller profiles off **and leave the Steam profile Test page** to remove the last listener and restore the selected controller's mode; or switch Input controller to Automatic. Do not force-close the app as the normal Undo path. No pairing, permission, game-data or firmware change is required. A prior signed application remains recoverable through the existing installer.

## Tools and evidence handling

`Tools/controller-probe/steam-wireless-receipt.swift` queries selected settings without changes by default. `--test-mode` performs the bounded two-second verified capture/restoration; `--observe` extends that controlled receipt window to three minutes. It sends no keyboard/mouse input. Summary counters and selected mode values are kept locally; no serial, account data or raw user sessions belong in git. The old description-only inventory was corrected for current Swift's direct CF object return type; it still opens no device.

The old no-SDL research receiver Wine patch remains unsuitable for shipping. This change does not install it or change the current working full-SDL controller bus.


## Installed hardware checkpoint

The source built with stable signing, passed deep/strict verification and signing continuity, and was installed through the recoverable app installer. Before launch, a read-only query verified original 3/0/1/0/2 settings on slot 1. Installed UI selects **Steam Controller (2015 · USB / receiver)** and reports **Receiving Steam Controller input (Wireless receiver · desktop controls captured)**. The user confirmed wireless aiming, touch gyro, haptics and normal keyboard typing all seem correct. After the user switched the controller off, the installed profile Test page showed **Connect a controller to test the profile here**; the receiver was not presented as an active controller. After wake, installed UI again showed full wireless receipt and live gyro data. Reconnected control-feel confirmation is still pending separately. This supersedes the installation/off-on pending rows above; cable replug, receiver unplug/replug and multiple simultaneous controllers remain broader manual checks.

The first production packaging attempt detected source edits during compilation and aborted; it was discarded. A fresh completed build was signed and installed. No failed or mixed-source candidate was installed. Later requested UI/label refinements are a separate incremental update.


## Subsequent field regressions: slow vertical movement and keyboard duplication

The user initially confirmed wireless aiming/haptics/typing and a successful wake, then reported slow up/down zigzags and renewed doubled physical-keyboard input. Gyro output was temporarily Off for isolation: the zigzag persisted, so it is not explained solely by gyro addition. The user's current X sensitivity (~947.6) is 3.25 times Y (~291.95), amplifying transverse raw motion. With Nokcandu closed, built-in desktop tracking felt straighter, though at lower sensitivity. Closing Nokcandu restored single-letter typing; no other Nokcandu/observer/Steam process remained. Do not describe wireless duplicate typing as resolved from the earlier successful check.

A passive twenty-gesture wireless capture recorded contact starts and ends. One vertical swipe approached Y=-30254, then -31702, and spent about 88 ms at the lower edge while X rolled from -2720 to +236. Replaying that actual sequence through the old processor produced coast X=20, Y=-1; both original and mirrored direction assertions failed. Short edge dwells now launch from the approach window before entering the outer 2% of coordinate bounds; ordinary direct motion is unchanged. Two tests verify the measured correction and retained diagonal flicks/rest cancellation. This specifically addresses coast direction, not all in-contact zigzagging.

Optional per-pad **Small movement steadiness** uses spatial hysteresis on each output axis. Missing/zero settings preserve raw behavior. It suppresses small back-and-forth wobble while allowing slow accumulated travel and diagonal motion; there is a configurable spatial reversal distance rather than a time-buffer delay. Two tests cover that behavior, unchanged zero mode and profile round-trip. Physical acceptance remains pending.

The gyro isolation field was restored to Mouse with all tuning preserved. Right-pad haptics was temporarily set to zero for the next duplicate-typing A/B test; its exact prior strength (~0.1618007) is saved locally for restoration. No source-level haptic defect has yet been established. Full follow-up suite: **628 tests, zero failures, 19 optional skips**. Do not skip the live typing/restore checks or call all wireless issues solved from this suite.


## Capture recovery and vertical tracking follow-up

A controlled mode-loss comparison showed that full vendor reports can continue while the remote returns to its measured desktop baseline. Stream timeout alone therefore did not recapture it. The installed follow-up checks selected mode settings on the serial feature queue once per second. If they exactly match this session's measured original, it releases outputs and permits verified recapture (at most three resets per ten seconds). Unknown/competing modes or unreadable replies pause mapping for explicit retry rather than repeatedly fighting another owner. Session checks discard late completions. A bounded hardware fault test restored only the receipt's measured baseline while reports continued; the app recaptured within four seconds. The earlier timeout-only comparison failed and must not be treated as sufficient.

Focused follow-up: 18 tests passed; debug and production app builds completed. The latest prior full suite remains 628 tests, zero failures, 19 optional integration skips, including passing privacy checks. Stable signing/continuity and recoverable installation passed. No permission, pairing or firmware changes were made.

With verified capture, no observer, gyro restored and movement haptics temporarily off, the user described slow vertical movement as “feels much better. acceptable for now.” They had also tuned X/Y to approximately 625/439 and steadiness to 0.725 px, so acceptance cannot be attributed to the filter alone. Keep their tuning. The measured edge-coast regression is covered by tests; all possible sensor wobble is not declared fixed.

A subsequent, more precise keyboard report changes the diagnosis: typing to Codex is normal, but physical keys double in Nokcandu's New Layer name field. In that same open dialog, six automated single key presses produced exactly `abcd 1`; user-operated physical keys then doubled. This is a reproduced distinction, not proof that the alert or haptics is the cause. A comparison with profiles off and the Steam source changed temporarily to Automatic is underway. A read-only hardware query in that state verified restoration to 3/0/1/0/2. The draft is disposable with user authorization. No generic key debouncer or speculative controller reset has been added.


## Physical keyboard and layer-name focus comparison

Profiles off plus Automatic source did not eliminate physical doubling: the field contained `aabbccdd` after a user typed `abcd`, even after restart. This excludes an active Steam source as a necessary condition for that reproduction. Two unconditional keyboard monitor installations were narrowed: calibration monitors now exist only for a configured shortcut and refresh when it changes; capture shortcuts exist only while at least one application has manual/automatic capture configured. Neither was configured on this Mac. No typed characters are recorded, modified or debounced.

The signed installed comparison passed 8 focused capture/privacy tests and a fresh full **628-test suite, zero failures, 19 optional skips**. User repeated the physical test and reported single letters; AX showed exactly `abcd`. This supports the idle-monitor change for that configuration, but does not identify which monitor/platform interaction caused it or certify configured global shortcuts. After source/master/feedback restoration a distinct focus failure remained: the user reported typing going into ChatGPT behind Nokcandu. The empty native alert and “waiting for full controller input” were observed; controller receipt subsequently resumed and the user confirmed it worked. Do not reinterpret that failed combined retest as proof of haptic or keyboard success.

Haptic strength is restored to the exact saved ~0.1618007. Latest user X/Y 625.1527/438.5115 and steadiness 0.72519 remain intact. User's newer pulse rate ~32.519/s and spacing 0.1 ms were preserved, rather than overwritten with an older snapshot. Steam source, master On and Everywhere assignment are restored. On normal quit, a read-only query again verified stable remote identity and exact original 3/0/1/0/2.

A separate UI follow-up replaces the native layer-name alert with a regular SwiftUI sheet and explicit text-field focus, retaining New/Rename, Cancel, Enter submission and empty-name validation. This addresses the reproduced unusable layer-name workflow; build and physical acceptance follow below. No controller or game behavior is changed by that UI follow-up.


## Reopened focus failure and touch-contact request

The first SwiftUI sheet passed a physical typing check and automated blank-name/Add/Enter/Rename/Cancel checks. Its disposable test layer was removed; only Base remained. **That was not sufficient:** the user reopened it independently and again reported that physical typing went to ChatGPT behind Nokcandu. The initial sheet-only fix is superseded by an explicit native keyboard-window/first-responder implementation. Controller receipt remained active afterward, and the user confirmed the Steam Controller was working; do not conflate this focus regression with a persistent radio failure.

`LayerNameField` now uses an AppKit text field, claims its own visible sheet's keyboard window once at presentation and on an explicit click, and delegates text changes/Return without replaying keys. It does not poll, forward physical events or reclaim focus after a user switches apps. Layer submission is guarded so default-button and text-field handling cannot add twice. Native correction acceptance is pending below.

The user also requested a pulse on simple pad contact. Optional per-pad `touchFeedback` is independent of movement enablement and available in all pad modes. It sends the same bounded finite pulse report on a rising contact only, with separate strength, no repeats while held and a 40/s contact-chatter bound. Preview defers to the active desktop owner to avoid duplicate feedback; the USB/receiver sender retains its existing lease, cancellation and one-in-flight radio guards. Two tests cover contact edges, per-pad separation, disabled/held behavior, reset, bounds, movement overlap, legacy decoding and round-trip; thirteen focused haptic/notification tests pass. Actual new touch feel remains a hardware acceptance gate.


## Final candidate installation checkpoint

Touch-contact tests and native field compiled in a completed production build. Full suite: **630 tests, zero failures, 19 optional integration skips**, including AppPrivacy tests. Deep/strict signature verification and signing continuity passed; the recoverable installer replaced only the application. No driver/helper or system-permission changes were made. Installed UI shows Touch haptics and Touch strength independently of Movement haptics. Right touch feedback was enabled at 20% for physical validation; the user's newly disabled Movement haptics and revised steadiness (~1.58015 px) were preserved, along with X/Y ~625/439 and touch gyro. Live receiver full-state receipt was visible before requesting the contact test. Native-field repeated typing and physical pulse acceptance follow below.


Installed contact-haptic acceptance: with right Touch haptics at 20% and Movement haptics Off, the user rested a finger, held still, lifted and touched again, and confirmed **one pulse on each touch**. This verifies the new contact behavior on this wireless controller's right pad; left-side feel and a new wired contact-pulse check remain untested. Both sides use the tested shared processor and existing side-addressed protocol.

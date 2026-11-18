# Stream stalls, responsiveness and statistics — November 17, 2026

## Reported regression and evidence

The user reports brief streaming freezes every few seconds over both Ethernet and Wi-Fi, independent of
bitrate and with AWDL disabled. VoidLink Extreme behaves better against the same host. Attaching a controller
appears to stop the freezes. This supersedes AWDL/channel hopping as a sufficient explanation for this report.
The user later found **Frames to buffer = 2**, a separate explanation for some cursor latency. A frame reserve
trades responsiveness for smoothing (a frame is 16.7 ms at 60 fps, 8.3 ms at 120 fps). The saved value is preserved.
Neither the original freeze nor improvement from this change has been physically reproduced here.

## Upstream comparison

Inspected the live [Integration branch](https://github.com/The-Fried-Fish/VoidLink-previously-moonlight-zwm/tree/Integration),
root revision `abc4fc2` shown in the browser, and these source files on November 17:

- [VideoDecoderRenderer.m](https://github.com/The-Fried-Fish/VoidLink-previously-moonlight-zwm/blob/Integration/VoidLink/Stream/VideoDecoderRenderer.m):
  serial user-interactive processing queues, decoded-frame queue, display-link pacing, queue/decode plot metrics,
  AVSampleBuffer rendering. Upstream sets presentation timestamps for target display refreshes and caches the
  decoded image format; Nokcandu currently enqueues display-immediate buffers and recreates the image format.
- [Connection.m](https://github.com/The-Fried-Fish/VoidLink-previously-moonlight-zwm/blob/Integration/VoidLink/Stream/Connection.m):
  counts full compressed frame bytes, infers missing frames from frame-number gaps, and records optional host
  latency min/average/max in tenths of a millisecond. These are richer than Nokcandu's previous averages/counts.
- [StreamFrameViewController.m](https://github.com/The-Fried-Fish/VoidLink-previously-moonlight-zwm/blob/Integration/VoidLink/ViewControllers/StreamFrameViewController.m):
  disables the application idle timer for streaming and restores it when stopping/failing. This is UIKit behavior;
  it is not proof of a macOS App Nap assertion in VoidLink Extreme.

A local VoidLink checkout was discovered but is on a September development branch, not the requested current
Integration revision; it was not treated as authoritative. Shell network access failed, so the current source
was inspected read-only through the browser. No upstream binaries or raw session logs were imported into git.

## Session activity protection

Confirmed source gap: `DesktopPad.attach()` acquires a latency-critical activity when an active profile has a
controller to map. The streaming window previously had no corresponding activity of its own. The controller
observation therefore fits a plausible scheduling/power-management cause. It does not prove App Nap caused
the periodic freezes; a controller could also alter Game Mode or other behavior.

The streaming window now owns `StreamSessionActivity` from connection startup until its shared finish path.
It requests `.userInitiated`, `.latencyCritical` and `.idleDisplaySleepDisabled` independently of controllers,
profiles, transport, bitrate, codec or statistics visibility. Normal stop, cancellation, connection failure,
remote termination, window closure and object destruction release the activity. Repeated starts/stops are
idempotent. Controller activities remain separately owned. This fixes the missing protection centrally;
physical no-controller acceptance remains pending.

No speculative network-buffer, packet-size, AWDL, codec or saved pacing changes were made for this report.
The separate renderer/queue differences above remain documented comparison points, not confirmed causes.

## Statistics and graphs

Text statistics retain Off / Frame rate and latency / Detailed. **Performance graphs** is a separate live
Boolean setting: text only, graphs only, both and neither are supported. The existing shortcut cycles only
the three text modes. Graphs default off for old and fresh profiles; existing text choices and explicit frame
buffers survive round trips. Changing visibility renders the cached snapshot rather than rolling another
partial interval. The sampling timer uses common run-loop modes.

Detailed statistics now include:

- Video payload bitrate and peak sampling-window bitrate, received/decoded/enqueued fps and queue occupancy
  sampled at decoded-frame arrival. Payload excludes packet headers, FEC, audio and missing frames.
- Optional host min/average/max, measured decoder-call-to-callback min/average/max, frame assembly time,
  pre-decoder queue time and decoded-to-layer enqueue wait.
- Actual selected codec from `videoSetup` (the offered codec mask no longer overwrites it), requested colour
  range, renderer/pacing, display maximum refresh rate, pending core frames and queued audio duration.
- Missing-frame estimates, decode failures and local pacing drops. Loss percentages/counts are since stream
  start with a common expected-frame denominator, so asynchronous callbacks across interval boundaries do not
  make a rate divide by the next interval's unrelated arrival count. Sequence wrap/restart is handled.
- Largest frame-arrival and display-callback gap in the sample interval.

The old decode metric started at the first received packet and included transport/assembly/queue work.
It now begins at the VideoToolbox decode call. Frame counts are recorded when `layer.enqueue` actually runs,
including the main-queue wait in presentation timing; posting work is no longer counted as a shown frame.
“Enqueued” is intentional: physical scanout and end-to-end input latency are not measured.

Three compact charts retain at most 120 one-second samples: transport RTT/RTT variation; decoder average/max
and presentation wait; maximum frame-arrival/display-callback gaps. Unknown data is N/A, never a false zero.
RTT variation is the core's transport estimate, not independently measured one-way latency or packet jitter.
Frame-number gaps can include recovery/intentional upstream discards and are not proof of a bad network.
A still desktop can legitimately have long frame-arrival gaps. No per-frame history is retained.

At the user's request the text is 9-point monospaced, with zero extra line spacing, 3-point section spacing,
5-point padding and a 32%-opaque black background (more transparent so gameplay shows through). Charts use
small type, 2-point section spacing and 50-point plot height. They do not intercept input. Final live appearance
has not been inspected on screen.

## Verification, migration and Undo

- Debug app compilation and **45 offline streaming/controller tests pass**, including 10 new session/activity
  and telemetry tests: independent graphs/text, backward-compatible decoding, preserved buffer=2, units,
  peak/elapsed sampling, missing values, sequence wrap/reset, delayed pacing callbacks, bounded history,
  concurrent decoder/presentation callbacks and activity release/idempotence.
- Broader streaming run aborted in the pre-existing HTTP fixture (`StreamTests.swift`, local listener/port
  creation followed by a force unwrap, signal 5). HTTP, pairing and clipboard fixture classes were excluded
  from the offline check. This is not a full-suite or live-network pass.
- At the initial checkpoint no signed update had been installed; the user subsequently built and installed
  it from Terminal. An exact comparison confirmed the installed executable matches `build/Nokcandu.app`.
  No settings, games, saves or launchers were rewritten. Fresh and existing installs use the same session
  protection next launch; missing `window.graphs` decodes false. Undo is the previous app/source; disabling
  graphs is independent and rollback readers ignore the extra field.

Hardware acceptance: compare the same moving scene/codec/resolution/FPS/pacing and host display, first over
Ethernet with no controller, then with the controller, then over Wi-Fi. Compare frame buffer 0 against the
user's saved 2 only as an explicit setting change. Observe RTT/variation, arrival gaps, display callback gaps,
decode maximum and presentation wait together. Check stop/error restores ordinary sleep behavior. Record
whether freezes, cursor responsiveness, sound and graph appearance actually improve before claiming parity
with VoidLink Extreme.

## Follow-up: activity protection did not stop the freezes

The user installed the build and still observed periodic freezes with the controller disconnected. This
supersedes activity protection as a sufficient fix; it remains appropriate session hygiene. The installed
stream log confirms the new metrics were running. During the receiver-disconnected window, RTT was usually
1 ms, decode averages about 3–4 ms, and recorded network/decode/pacing drops were zero. Display callback
gaps repeatedly reached about 480–500 ms, while frame-arrival gaps were typically under about 60 ms.
The controller log records disconnect at 01:38:55 UTC and reconnect at 01:44:03 UTC (November 18 UTC,
November 17 locally), covering the repeated display-gap window. These are aggregate observations, not a
raw session log committed to the repository. Process sampling was unavailable in the restricted context.

### Root cause in the input reader

`SteamControllerUSB.expire()` retries discovery every two seconds while no controller is captured. The
receiver's four vendor channels remain present when the controller is off. `chooseController()` previously
performed every settings/identity/lease attempt synchronously on the main actor, including bounded HID
retries and sleeps. The empty-slot searches therefore blocked the same thread that enqueues video frames,
runs display callbacks and handles input. Finding a live controller stops those periodic scans. This is a
concrete mechanism matching the timing and controller-dependent report, beyond the earlier power hypothesis.

An explicit display-link frame-rate request, as in VoidLink, was initially considered from the display-gap
metric. That candidate was removed before installation once the blocking empty-slot probe was identified,
to isolate the evidenced cause. No new wake-up timer or render/pacing default was introduced.

### Fix and verification

`SteamControllerDiscovery` now serializes read-only liveness probes on the existing feature queue. Only one
scan is pending at a time. Cancellation invalidates old generations and stops probing subsequent slots.
Results return to main, where manager/session/channel identity are checked; only a responding controller is
then allowed through the existing settings/remote-identity/journal/mode-lease verification before input is
published. An unsafe/failed capture advances to other candidates. Cancellation on stop/new 2026 capture
prevents stale results from taking ownership. Empty receivers no longer perform their repeated timeouts on
the UI thread. One-time successful capture and quit restoration still use their existing serialized paths;
this change does not claim that every controller operation has moved off main.

Additional telemetry now separates layer-enqueue gaps from display-callback gaps and logs decode/presentation
maxima plus actual sampling duration, so a catch-up burst cannot hide a main-queue stall behind good average
fps. The third graph includes layer-enqueue cadence.

**72 offline streaming/controller tests passed** at this checkpoint. New concurrency regressions keep a
mock HID probe blocked while proving the main queue progresses, reject overlapping scans, select the first
responding slot, and reject stale results after stop/restart. Additional timing tests distinguish a stalled
display callback from healthy arrival/enqueue cadence and preserve enqueue gaps across sample rolls. The
final incremental debug build also validates the native reader wiring. Existing lease/identity/restore tests
are included. The user subsequently installed this candidate and confirmed the streaming freeze is fixed
(“You fixed it!!!”). This is acceptance of the reported receiver/controller-dependent stream freeze;
it does not establish every codec, display or network configuration. The next separately reported issue is
native macOS Steam competing with Nokcandu for Steam Controller mode ownership, including capture staying
paused after Steam quits. No coexistence implementation was requested at this checkpoint.

Fresh/existing installations use the same discovery worker without data migration. Profiles, explicit
buffer/pacing values, games/saves, launchers and mode journals are preserved. Undo is the previous app/source.
Retest with the receiver left plugged in and the controller off; verify no recurring freeze, then reconnect
and test input plus ordinary quit/restoration. The expected diagnostic is an off-main discovery duration
without corresponding half-second display/enqueue gaps.

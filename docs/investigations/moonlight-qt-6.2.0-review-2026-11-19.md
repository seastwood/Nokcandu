# Moonlight PC 6.2.0 review for Streams (November 19, 2026)

Asked for: improvements to Nokcandu Streams based on [Moonlight PC v6.2.0](https://github.com/moonlight-stream/moonlight-qt/releases/tag/v6.2.0), then "do everything possible that will be an improvement".

## Method

Moonlight PC's renderers (libplacebo, Metal, D3D11, KMSDRM, EGL) don't apply: Nokcandu decodes with VideoToolbox and shows
frames on an `AVSampleBufferDisplayLayer`. What applies is moonlight-common-c (the streaming core Nokcandu carries in
`Sources/NokcanduStreamCore/moonlight/`, from VoidLink's fork) and client behaviour. Compared:

- moonlight-common-c `8599b60..f900dd4` (the submodule commits of Moonlight PC v6.1.0 and v6.2.0) against Nokcandu's copy, by
  looking for each upstream change in our files.
- moonlight-qt `v6.1.0..v6.2.0` commits touching macOS, VideoToolbox, input, HDR, colour range and host requests.

Already in Nokcandu's copy (from VoidLink): RTSP hardening against oversized responses and malformed Session headers
(`7b026e7`), dual-touchpad events (`2600bea`), microsecond presentation times. Already equivalent in Nokcandu: a manual
bitrate isn't reset by resolution changes (`bitrateKbps` is nil only for Automatic), Game Mode, AV1 on M3 and later.

## Changes made

| Change | Upstream | Files | Scope |
| --- | --- | --- | --- |
| Loss recovery: a lost multi-block frame no longer stops the *next* lost frame being reported; the right frame number is reported | common-c `d85371c` | `RtpVideoQueue.c` | every stream |
| A partly received key frame that is dropped now asks for a new key frame (it waited for a reference-invalidation frame) | common-c `be43885` | `VideoDepacketizer.c` | every stream |
| No speculative loss reports when reference-frame invalidation is off (upstream: could drop 120 frames in a row) | common-c `62e0663` | `RtpVideoQueue.c` | hosts/codecs without RFI |
| `MODIFIER_EXTENDED`: Return and keypad Enter (both VK 0x0D) and the other 0xE0 keys are told apart | common-c `f900dd4`, qt `c0f62ad6` | `InputStream.c`, `Limelight.h`, `StreamKeys.isExtended`, `StreamKeyboard` | Sunshine hosts that know the flag; stripped for others by the core |
| `LI_CTYPE_STEAM` defined | common-c `874ac95` | `Limelight.h` | not sent yet (see below) |
| HDR: the host's mastering-display and content-light metadata attached to every HDR frame, plus a PQ/HLG CGColorSpace | qt `200cab9d` and the AVSampleBufferDisplayLayer renderer | `StreamHDRMetadata`, `StreamVideoDecoder.setHDR/attachHDR` | HDR streams only; SDR frames untouched |
| 10-bit decoding honours full range (it always asked VideoToolbox for video-range buffers) | found while making full range the default | `StreamVideoDecoder.makeSession` | HDR/10-bit with full range |
| Full-range colour on for new stream profiles | qt `c1623ff4` | `StreamProfile.Video.fullRange` | new profiles only; saved ones keep their value; profiles saved before the field existed decode as limited |
| DualSense adaptive triggers from the host | qt `d9c7a245` (raw report through SDL) | `StreamAdaptiveTrigger` (decoder), `StreamGamepads.adaptiveTriggers`, `StreamConnection` | DualSense players; needs a host that sends them |
| Real client ID for Sunshine-family hosts (NVIDIA keeps the shared placeholder) | qt `170801ba` | `StreamIdentity.clientID`, `StreamClient.sendsClientID` | Sunshine/Apollo; every request of a client uses the same ID |
| ⌃⌥⇧K sends the Mac's shortcuts to the host or keeps them on the Mac, for the running stream | qt `29294553` (Ctrl+Alt+Shift+K) | `StreamWindowController.toggleSystemShortcuts` | applies immediately; saved setting unchanged |
| Location Services Wi-Fi scan stutter in troubleshooting | 6.2.0 known issue | `streams.md` | documentation |

### Adaptive triggers

GameController has no raw-report API, so the host's raw DualSense effect bytes are translated (`StreamAdaptiveTrigger.decode`):
0x05 off; 0x21 feedback (10 zones, 3-bit strength per zone → `setModeFeedback(resistiveStrengths:)`); 0x25 weapon and 0x22 bow
(start/end zone bits, strength → `setModeWeaponWithStartPosition`); 0x26 vibration (zones, amplitudes, frequency byte 8 →
`setModeVibration(amplitudes:frequency:)`); the older simple effects 0x01, 0x02, 0x06. Galloping, machine and anything unknown
leave the trigger as it is and are logged ("no equivalent"). Byte layouts follow Nielk1's DualSense trigger-effect generator
(the format games write and the host forwards); bow's snap-back force is lost. Triggers the host changed are switched off
when the stream's controllers stop. The first eight effects of a stream are logged as "Controller: left/right adaptive trigger
effect 0x…".

### Client ID

Moonlight PC sends `0123456789ABCDEF` to NVIDIA GameStream (which shares one session among clients) and its real ID to
other hosts so they can manage sessions per client. Nokcandu's ID is the first 8 bytes of SHA-256 of its certificate (16
uppercase hex digits): stable, no new file. A `StreamClient` sends it when the saved host's version is Sunshine-style
(`…-1`), and `serverInfo` updates the choice from the host's answer, so launch, resume, quit and clipboard requests of one
stream agree. Hosts identify paired clients by certificate, so existing pairings are unaffected (Moonlight PC users made the
same switch with existing pairings).

## Not done, and why

- **Sending `LI_CTYPE_STEAM`**: safe with Sunshine (checked in its source, `4fe1421`, November 19: an unknown type falls
  back to capabilities, giving a DualSense with motion or a touchpad, otherwise Xbox), but nothing in Nokcandu would use it
  well yet. "Controller as it is" doesn't send a Steam Controller at all (`SteamControllerUSB` feeds profiles, not
  `MappedGamepads`), and through a profile the host gets the profile's remapped output, which isn't a Steam Controller.
  Add it when "as it is" passes a Steam Controller's trackpads and motion through, as Moonlight PC does.
- **Cropping slightly oversized frames** (qt `d865c779`) and **chroma co-siting** fixes: Moonlight renderer issues;
  VideoToolbox applies the stream's clean aperture and the display layer converts colour itself.
- **Disabled bitrate readout** (qt `8ed71447`, FEC accuracy): our detailed statistics count payload bytes received; whether
  they share that inaccuracy wasn't measured.
- **Cursor not captured in windowed mode by default**: a design choice; Nokcandu's Capture mouse mode captures while the
  stream window is in front.

## Verification

- Built and installed on the user's Mac through the development watcher (`build-app.sh --test --install`): all 928 tests
  passed (21 skipped), including new `StreamAdaptiveTriggerTests`, `StreamHDRMetadataTests` (byte layout against a known
  BT.2020 example and the core struct read by bytes, since Swift can't import its anonymous-struct array), `StreamClientIDTests`
  and `StreamProtocolTests.testExtendedKeys`.
- **Not yet verified with a host**: recovery behaviour under packet loss, keypad Enter in a game, HDR brightness/tonemapping,
  adaptive triggers (needs a host that forwards them), the client ID with Apollo, ⌃⌥⇧K.

## Undo

- Core patches: revert the four hunks in `RtpVideoQueue.c`/`VideoDepacketizer.c` (upstream commits above).
- Full range: turn off "Full-range colour" in the stream profile.
- Client ID: `StreamClient(…, sunshine: false)` at the call sites; no data was written.
- Nothing migrates; older builds read the same saved profiles.

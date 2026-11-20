# Metal renderer, V-sync off and decode-to-screen latency (November 19, 2026)

Asked for: a Metal rendering option if it lowers latency — "as close as possible to real-time, zero-latency streaming".

## Why Metal

Nokcandu showed frames only through `AVSampleBufferDisplayLayer`, which always waits for a display refresh and is
composited by the window server. Moonlight PC moved to a `CAMetalLayer` renderer in 2024 mainly to allow V-sync off
(`displaySyncEnabled = false`), which shows a frame as soon as it's drawn (it can tear). Its history, read on November 19:

- `db062390` (Feb 2024) CAMetalLayer renderer: "allows v-sync to be disabled on macOS".
- `12624bc5`: three drawables are needed for macOS's direct-to-display path; with two, every frame is composited and
  latency is higher. Tearing (V-sync off) also needs the direct path.
- `a093a0ae` (Mar 2024): display layer restored for discrete/eGPU Macs, which sometimes couldn't import decoded frames
  into Metal; `9cbba106` (May 2026) made Metal default on all Macs again with a test render and automatic fallback.
- `57db2001`, `ccaca685` (Oct 2025): pacing rewritten for macOS 26; no `CAMetalDisplayLink` on Intel Macs (a skipped
  frame flashes black in Direct mode).
- `4453e4ae` (Jul 2026): a renderer picker, because reports of which renderer is best conflict even on the same systems.
- `2d600c4e` (Nov 15, 2026): `kCVMetalTextureUsage` goes in the texture cache's *texture* attributes.

Moonlight PC 6.2.0's new default (libplacebo through MoltenVK) wasn't copied: it adds Vulkan and FFmpeg's stack, against
the goal of a lightweight app.

## What was built

- **`StreamMetalRenderer`** (`Sources/Nokcandu/Streams/StreamMetalRenderer.swift`), ported from Moonlight's VTMetalRenderer:
  VideoToolbox's bi-planar buffers (8/10-bit, 4:2:0/4:4:4, limited/full range) become Metal textures through a
  `CVMetalTextureCache`, and one fragment shader converts YUV to RGB with Moonlight's premultiplied matrices and chroma
  siting (`StreamColorConversion` in NokcanduCore, tested). The picture is the buffer's clean aperture, fitted with its
  shape kept. Three drawables, opaque, framebuffer-only. HDR: PQ/HLG output into a 10-bit layer in the ITU-R 2100 colour
  space with EDR and `CAEDRMetadata.hdr10` from the host's metadata (optical output scale 203, as Moonlight).
- **Newest frame wins**: frames are drawn on a dedicated render queue; a frame still waiting when a newer one arrives is
  replaced (counted as a pacing drop), so the screen never falls behind. The decoder thread never waits for a drawable.
- **Pacing is unchanged**: Lowest latency sends each frame straight from the decoder; Balanced/Smoothest go through the
  display refresh as before. With Metal and V-sync off, Lowest latency is the fastest path.
- **Fallback**: if Metal can't be set up (no device, texture cache or shader) the display layer is used with a message;
  if 30 frames in a row can't be read into Metal during a stream, it switches back by itself and says so.
- **Settings** (Video): Renderer — "Display layer (AVSampleBufferDisplayLayer)" (default) or "Metal (CAMetalLayer)"; V-sync
  (Metal only, on by default). Both apply immediately during a stream (a key frame is requested so the new renderer has a
  picture at once); saved profiles without the fields decode as the display layer with V-sync on.
- **Nothing over the picture when there's nothing to show**: the overlay view is hidden when no statistics, graphs,
  hints or warnings are displayed, so macOS can send the picture straight to the display (both renderers benefit; V-sync
  off depends on it).

## Measuring latency

Statistics now show **Decode → screen** and **this Mac total** (the frame's first packet arriving → on screen), with
maxima in Detailed, a line in the performance graphs and in the 5-second "Video stats" log line:

- Metal: **measured** — each drawable's presented handler reports when it was actually shown (`presentedTime`).
- Display layer: **estimated** — it can't report presentation; the estimate is the first display refresh after the frame
  was handed over plus one refresh for the window server. Shown as "(estimated)".

Detailed statistics also show an estimated total: host processing + half the network RTT + this Mac. Encoding time on the
host is part of host processing as Sunshine reports it; the time for the game to render a frame and for the host to
capture it isn't, so this isn't true glass-to-glass.

To compare on this Mac: same stream, full screen, Lowest latency, statistics on Basic for a few seconds (then off), once
per renderer (display layer; Metal V-sync on; Metal V-sync off), and compare "Decode → screen" and "this Mac total" in
`~/Library/Logs/Nokcandu/Streams.log`. Statistics on screen can keep the picture from the direct path, so the log line
with statistics off is the better number.

## Verification

- Built and installed through the development watcher; all 934 tests passed (21 skipped), including
  `StreamRendererTests`: limited/full-range and 10-bit black/white and BT.709 red through the shader maths, matrix and
  chroma-siting choices, aspect fit, the on-screen latency aggregates, old profiles decoding as the display layer, and the
  renderer/V-sync settings applying live.
- **Not yet verified with a stream**: the picture itself (colours, HDR, 4:4:4), tearing and latency with V-sync off, the
  direct-to-display path on a MacBook with a notch (full screen stops below the camera housing, which may keep the window
  server compositing), behaviour on Intel Macs and external GPUs.

## Tested on the user's Mac (November 19, evening)

- **Baseline with a real stream** (nokenwpc, AV1 2560×1600 at 120 fps, Lowest latency, full screen, display layer): decode
  3.3–4.3 ms, decode → screen 12.3–13.5 ms (estimated; max ~16.9), this Mac total (first packet → screen) ~17.4 ms, RTT 1 ms,
  no drops of any kind over ~10 minutes. The display refresh ran at 8.3–8.7 ms (120 Hz). The desktop sent ~32 fps.
- **Metal on the GPU, offscreen** (`StreamMetalRendererTests`, the renderer moved into NokcanduCore for this): correct colours
  for 8-bit limited/full range BT.709 (white, black, grey, red, green, blue within 3–4 levels), 10-bit BT.2020, 4:4:4 8- and
  10-bit; letterboxing; real H.264 (limited and full range) and HEVC frames from VideoToolbox drawn with the right quadrant
  colours; 240 submits return in under 50 ms (the decoder never waits); GPU time per 2560×1600 frame under 3 ms.
- **Quitting during a stream** (development install): "Ending the stream because Nokcandu is quitting", core cleaned up, and
  the host answered again straight after. This confirms the November 14 change.
- **Not tested live**: the Mac's screen locked during the session, which blocks clicks and stops the display, so a Metal
  stream (and its measured latency, V-sync off and tearing) still needs to be run with the screen on.

## First live run (November 19, 18:40)

The user streamed with Metal, V-sync off (AV1 2560×1600, 120 fps, full range, M4): decode → screen **5.7 ms measured**
(display layer ~12.7 ms estimated) and this Mac's total **~8.6–9 ms** (display layer ~17.4 ms), no network or decode drops.
The picture looked bright and washed out: the layer was tagged BT.709 (`kCGColorSpaceITUR_709`), whose transfer curve
macOS converts from, lifting mid-tones. Corrected to sRGB (BT.2020 primaries: `itur_2020_sRGBGamma`); needs the user's look.

## Washed-out picture: the real cause (November 19, 19:00)

Both renderers looked washed out (46% of pixels near white). The user fixed it by turning full range off and using End and
Quit App, then starting again. Cause: the host was still running the app from an earlier limited-range session; a
*resumed* app keeps the range it started with, so the host sent limited range while Nokcandu (full range now being the
default) decoded it as full. Fix: `StreamVideoDecoder.makeSession` now takes the range from the stream itself (the
format description's `FullRangeVideo`, from the H.264/HEVC VUI or the AV1 sequence header) and logs a mismatch, so a
resumed or mismatched session always shows correctly. The BT.709 → sRGB layer tag (above) was a separate, smaller error
(Metal's mid-tones ~8 levels off from the display layer).

## V-sync off, the notch and the refresh rate (November 19, 19:00–19:25)

- Native full screen, Metal, V-sync off, statistics off, layer in the display's colour space: **~5.3–5.7 ms** decode →
  screen (~0.6 ms decode → drawn, the rest until presentation), this Mac's total **~8.5–9 ms**.
- Tried and **removed**: "Cover the whole display", a borderless window over the whole panel (beside the camera housing,
  menu bar and Dock hidden), on the idea that a screen-sized layer would be scanned out directly. Measured under the same
  conditions it was much worse: **~13.7 ms** (and ~9.7 ms earlier), likely because it loses what macOS's own full screen
  gets (Game Mode, refresh handling). Avoid repeating this.
- The panel's refresh dropped from 120 Hz (8.4 ms between refreshes, 22:41) to 60 Hz (16.7 ms, from ~19:15), with
  macOS reporting 60 Hz as the maximum and two displays connected: Low Power Mode or a mirrored second display. The stream
  now asks the display link for the screen's top rate (`holdTopRefreshRate`) so a ProMotion panel isn't lowered to the
  content's frame rate; at 120 Hz expect the lower figure above.
- Colour in the display's own space (sRGB mapped to P3 in the shader) took decode → screen from ~6.2 to ~5.3 ms.

## Undo

Choose "Display layer (AVSampleBufferDisplayLayer)" in the stream profile (the default). No files or migrations.

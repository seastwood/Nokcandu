# Presentation regression probes

These are developer tests, not game components. Build with the llvm-mingw toolchain cached by
`Engine/winemac/build.sh`. Run in a disposable prefix with the renderer being tested; do not change a
user's game prefix to run a probe.

## Fullscreen, scaling and input

`probe.c` draws a grid and corner click targets, reports the Windows screen/client dimensions, and
exercises display-mode changes, clipping and relative mouse input. Its comments list the controls.

## Cross-process Metal child window

`metal-child.c` creates a top-level window and child HWND in one process. A separate worker creates a
D3D11 swapchain targeting that **foreign child** and presents 90 colored frames. The parent pumps
messages while waiting, then closes its own windows. A 20-second limit terminates only its own worker.
This exercises the missing launcher/browser path without installing or signing into a launcher.

Build, for example, after building the driver:

```sh
build/winemac-work/llvm-mingw-20261006-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang \
  Tools/presentation-probe/metal-child.c -o /tmp/nok-metal-child-probe.exe \
  -ld3d11 -ldxgi -ldxguid -luser32
```

Run with the test engine's normal library paths, DXMT selection and a separate `WINEPREFIX`.
For the Sikarugir DXMT cross-process path, use `DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN=1`.
Pass `--root` to compare a foreign top-level target instead of a child HWND.
The `.log` beside the executable records HRESULTs and the worker exit code. Zero is success.
A successful Present call is an API check; separately verify the visible launcher, virtual-screen
scaling, input and restart behavior before claiming that the launcher rendering regression is fixed.

October 30, 2026: the earlier Wine 11 driver failed with the explicit unsupported cross-process child
swapchain diagnostic. The candidate including the child-layer port completed creation, target view,
90 Presents and worker exit successfully. See the dated Wine 11 investigation under `docs/`.

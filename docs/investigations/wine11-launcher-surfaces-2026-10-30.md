# Wine 11 launcher surfaces — October 30, 2026

## Result and scope

On the M4 MacBook Air, Steam's sign-in page rendered inside Nokcandu's virtual screen with the new
Wine 11 driver, GPU browser drawing, and DXMT selected **only inside Steam's browser workers**. The
Steam host retained Older 3D graphics for games. The user confirmed the visible sign-in page and the final integrated normal test.
The installed Steam copy then rendered after synchronizing its saved browser preference. A follow-up
shared-driver correction fixed stale content during live resizing and native fullscreen; the user
confirmed both now work without minimizing/restoring. This is launcher presentation verification,
not a gameplay/performance result.

EA was subsequently tested on Wine 11.0. Its already-running process initially used the older driver;
restarting it after the shared installer updated the driver fixed resizing/fullscreen. The user
confirmed both behaviors in the installed EA launcher as well.

The driver correction is shared infrastructure: all applications using Nokcandu's Wine 11.0 driver
receive Metal-surface queries, presentation notifications and cross-process child-layer hosting.
The browser renderer policy is explicitly Steam-specific, limited to Wine 11.0 and an exact
`steamwebhelper.exe` basename. EA/Battle.net/Ubisoft receive the shared driver when using that engine. EA's Wine 11 pages and
resize/fullscreen were verified after its driver refresh. Battle.net/Ubisoft's Wine 11 rendering has
not been reverified here. This fix does not switch their selected engine versions. Do not claim all launchers/renderers are now verified.

## Findings

1. Sikarugir's Wine 11 DXMT uses `MACDRV_ESCAPE_GET_SURFACE` (6790) and RELEASE (6791). The output has
   two UINT64 fields: surface and layer. Wine MR 11058 publishes that exact interface; inspection of
   the preserved stock driver confirmed the constants/layout. The missing escape prevented surface
   creation, but adding it alone did not fix Steam.
2. Metal frame acquisition must notify Wine's client-surface machinery that rendering has begun.
   CodeWeavers' public LGPL Wine source provides `WineMetalLayer` / `CLIENT_SURFACE_PRESENTED`.
   Nokcandu's scaled inner Metal layer needs the same notification, not only its outer backing layer.
   Queued events retain/release the associated client surface; detachment clears its view association.
3. The upstream cross-process swapchain patch already present only supported foreign top-level
   windows. It explicitly rejected foreign **child** HWNDs. CEF's browser/GPU process split needs the
   child case: host the remote CAContext in the owning root and maintain child geometry, clipping,
   ordering and replacement lifetime. The new child-layer port supplies this path.
4. Renderer choice and browser drawing are separate from driver support. Steam's default software
   path remained black even with the corrected driver. A DXMT/GPU browser rendered. Selecting DXMT
   only for the browser worker preserved the game's chosen graphics mode.
5. Setting Unix environment variables inside a native constructor is too late to change the Windows
   process environment block inherited from its parent. DXMT's cross-process capability must be
   exported by the Steam launcher before process creation. Otherwise the isolated worker still
   reports `CreateSwapChain: cross-process swapchain not supported yet`.
6. Existing Steam can retain `HKCU\Software\Valve\Steam\GPUAccelWebViewsV3=0` even when Nokcandu's
   GPU drawing switch is on. The clean copy did not have that saved off value. Automatic virtual-screen
   sizing rendered in the clean copy, ruling out the size difference. The installed copy rendered
   after its saved DWORD was set to 1. The normal Steam helper now synchronizes that one value to
   Nokcandu's effective choice before starting Steam. Wine 10's internal preference is untouched
   unless Nokcandu has an explicit saved drawing choice.
7. Remote browser layers are CALayerHosts, not NSView subviews. Nokcandu's existing virtual-screen
   relayout scaled normal/GDI/Metal views but skipped these hosts. This left Steam at its old size
   until minimize/restore and too small in fullscreen. Patch 0010 exports remote content in fixed
   Windows-pixel units, keeps its origin local, and transforms every hosted child target during the
   same presentation relayout. Content sizes stay stable across host scale and retina changes.
   Non-presented windows retain their existing point/retina path. The installed Steam resize and
   fullscreen checks both passed after this correction.
8. A stock-driver control must actually render before it can validate a comparison. Both the cloned
   prefix and a clean Steam prefix were black with the stock driver in the configurations tried.
   Claude's earlier “stock works” observation was not reproduced in those controls. Also, Nokcandu's
   background refresh can reinstall its bundled driver, invalidating a manually restored stock test.
   Pause that refresh or use a fully isolated app/engine/prefix and verify the installed hashes.

## Trial record

| Comparison | Result |
| --- | --- |
| ExtEscape interface only, isolated Steam copy | User: black. |
| ExtEscape + upstream OpenGL presentation / stale client-view corrections | User: black. |
| Restored original driver, simplified DXMT launch environment | User: black; invalid as a known-working control. |
| Original driver through full normal Steam helper, DXMT | User: black. |
| Original driver through normal helper, Older 3D | User: black. |
| Clean prefix, original driver, Older 3D | User: black; not explained by copied browser cache alone. |
| Metal notification candidate before child-layer port | No separate reliable visual result; superseded before the reply. Do not count the later success as proof this intermediate worked. |
| Child-layer driver + host DXMT + GPU browser + inherited cross-process capability | User: sign-in page renders in virtual screen. |
| Corrected driver, default Older 3D/software browser | User: black again. |
| Software/single-process Steam command-line experiment | No independent visual result; removed, not shipped. |
| Browser-only DXMT with software drawing | User: black. |
| Browser-only DXMT/GPU, capability set only in Unix constructor | No usable window; renderer log rejected cross-process swapchain. |
| Browser-only DXMT/GPU, capability inherited from launcher | User: sign-in page renders; game's Older 3D selection retained. |
| Built native helper + generated launcher, no test overrides | User: sign-in page renders. |
| Installed Steam, same update | User: black; existing saved internal GPU preference was off. |
| Clean integrated test using Automatic virtual-screen size | User: renders; virtual size was not the remaining cause. |
| Installed Steam with its saved GPU preference aligned to Nokcandu | User: renders. |
| Rendered installed Steam, initial child-layer port | User: content stayed at old size while resizing; fullscreen left a small picture. Minimize/restore refreshed it. |
| Shared remote-layer presentation relayout (0010) | User: both live resize and fullscreen work correctly without minimize/restore. |
| EA on Wine 11, old driver still in running process | Page rendered but did not scale. |
| EA restarted after shared compatibility-checked driver update | User: resize and fullscreen both work correctly. |

The first child-layer build required adapting Wine 11.16's three-argument capture callback assumptions
to Wine 11.0's two-argument API. The old capture window is obtained before replacing its association.
The rejected intermediate did not ship.

## Reproducible checks

`Tools/presentation-probe/metal-child.c` creates a child HWND in a parent process and asks a separate
worker to create a D3D11 swapchain targeting it. The parent pumps messages; the worker presents 90
colored frames. Logs are local beside the probe, with no account data.

- Before child-layer support: driver printed the explicit unimplemented foreign-child diagnostic;
  DXMT could not get its Metal layer and the worker exited 3.
- After: swapchain creation, backbuffer, target view, Present and worker exit all returned success.
- The foreign top-level comparison with `--root` also passed creation and presentation.
- An API success alone does not establish visible rendering, input, scaling or gameplay. Steam's
  visible sign-in page was separately confirmed by the user.

The Swift checks cover renderer isolation from games/unrelated helpers, exact worker matching,
missing renderer roots, Wine-version defaults, retained software/GPU choices, generated shell syntax
and browser policy in the restart identity. The full suite passed 199 tests with 6 optional skips.
The actual generated startup block also synchronized an existing saved GPU DWORD from 1 to 0 and
0 to 1 in the disposable prefix. The foreign-child API probe passed with virtual presentation enabled
after the resize correction. Signed app verification passed.

## Implementation, fresh installs and migration

Wine 11 patches 0005–0010 are built by the existing checksummed driver build. Wine 10's patch series
is unchanged. Existing driver installation verifies Wine server request numbering, keeps the engine's
original driver and updates outdated Nokcandu drivers only through its established closed-engine
path. The new binary source hash makes the old custom driver outdated. Normal restoration/engine
rollback still uses that engine's original files.

`SharedSteam.helperScript` enables the browser policy only for the tested Wine 11.0 runtime with DXMT
and the native helper present. The helper's early constructor selects DXMT for the exact browser
worker and removes competing renderer paths from that process. Steam itself and games retain their
chosen renderer. There are no Steam executable edits or downloaded replacement browser binaries.
The corrected native helper is copied by the existing helper refresh mechanism.

Wine 10 still defaults to software browser drawing. Wine 11 defaults to GPU drawing when the browser
policy is available. Existing GPU-on markers remain effective. Previously, absence of a marker meant
“off” and did not distinguish a user choice from the default; that unrecorded state follows the new
engine-specific default. New explicit off choices use `steam-software` and survive updates/switches.
The helper also synchronizes Steam's own `GPUAccelWebViewsV3` DWORD before starting it, so an older
saved off value cannot defeat the effective Nokcandu setting. Choosing software synchronizes 0.
The UI explains that GPU drawing is recommended on Wine 11. Browser policy and effective drawing
mode participate in Steam's running-configuration identity, so a changed policy requires restart.

Undo: choose software drawing explicitly (may reproduce black pages on Wine 11), disable the virtual
screen to restore the stock driver through the existing mechanism, or roll the engine back to Wine 10.
Do not copy an original driver from a different engine into the installed one. Game files and saves
are not edited by these fixes.

## Source provenance

- [Wine MR 11058](https://gitlab.winehq.org/wine/wine/-/merge_requests/11058): Metal ExtEscape interface.
- Upstream Wine MRs 10185 and 11567: OpenGL presentation and stale client-view visibility.
- [CodeWeavers public sources](https://www.codeweavers.com/crossover/source), CrossOver 26.3.0 source
  archive: SHA-256 `ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872`.
  Only LGPL Wine driver source is ported; copyright/license notices are retained. No commercial
  CrossOver binary is redistributed.
- [Foreign-child hosting patch](https://github.com/macgameport/cities-skylines-2-macos/blob/main/scripts/winemac-crossprocess-child-core.patch)
  and [Wine bug 60263](https://bugs.winehq.org/show_bug.cgi?id=60263). The source patch explicitly
  discloses AI assistance and offers its Wine modifications under LGPL-2.1-or-later. The port retains
  that notice and adapts the Wine 11.0 capture/destruction integration.

No private game/runtime binaries, credentials or raw launcher account logs are committed.

# Nokcandu's Wine Mac driver

Wine's Mac display driver (`winemac.so` and `winemac.drv`), built from Wine's own source with a small,
reviewable patch series. It drops into the matching supported Sikarugir Wine 10.0 or 11.0 engine, and is the
place for display features that can't be done from outside Wine, starting with fullscreen games in a
resizable Mac window (one real window, so Mission Control, Spaces and focus behave).

Owning this build is also groundwork for Apple silicon: the same patches apply to the Mac driver of an
ARM64EC Wine (Wine's own, or a project such as MetalSharp Wine), which runs games' x86 code through FEX
instead of Rosetta.

## Build

    Engine/winemac/build.sh            # -> build/winemac/{x86_64-unix,x86_64-windows,i386-windows}

Downloads (checksummed, `checksums/`): Wine 10.0 source, GNU Bison 3.8.2, llvm-mingw 20261006. Needs Xcode's
command line tools. Output includes `SHA256SUMS`.

## Patches

- `0001-macdrv-functions-for-d3dmetal-and-dxmt.patch`: exports `macdrv_functions`, the table Apple's D3DMetal
  and DXMT use to reach Wine's Metal views, with the registry callbacks it needs. From the Wine 10.0
  source published in PhoenicisOrg/winecx (LGPL-2.1-or-later; its copyright notice is kept in the patch). The Sikarugir engine's own
  `winemac.so` exports the same table, so the replacement keeps Apple Metal and DXMT working.

## License

Wine and these patches are LGPL-2.1-or-later. Distributed builds include this source (Wine's tarball + the
patches) and the build script, so the binaries can be rebuilt and replaced.

## Wine 11 launcher presentation

`patches-11.0/0005` ports Wine MR 11058's Metal surface ExtEscape interface. `0006` and `0007` port
upstream OpenGL presentation/stale client-view corrections. `0008` ports the LGPL WineMetalLayer
presentation event from CodeWeavers' public 26.3.0 Wine sources, including Nokcandu's scaled inner
layer and retained event ownership. `0009` adds foreign child-window layer hosting, ported from the
LGPL source linked in its header, with Wine 11.0 capture/destruction adaptations. Original notices
are retained. Source archive checksum and the exact scope of testing are recorded in
[the investigation](../../docs/investigations/wine11-launcher-surfaces-2026-10-30.md).

Build with `WINE_VERSION=11.0 Engine/winemac/build.sh`. This changes neither the Wine 10 patch series
nor a game's renderer settings. The separate-process surface regression probe is under
`Tools/presentation-probe/`; launcher pages also need visible testing in their normal launch path.

`0010` integrates remote child-layer hosts into virtual-screen relayout. Remote producers export
fixed Windows-pixel bounds; the owning window transforms hosted targets on resize/fullscreen,
independently of the rendering process's scale. The user verified live resizing and fullscreen in
installed Steam without minimize/restore.

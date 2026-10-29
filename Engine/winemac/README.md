# Nokcandu's Wine Mac driver

Wine's Mac display driver (`winemac.so` and `winemac.drv`), built from Wine's own source with a small,
reviewable patch series. It drops into the Sikarugir Wine 10.0 engine that Nokcandu uses today, and is the
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
  and DXMT use to reach Wine's Metal views, with the registry callbacks it needs. From CrossOver's Wine 10.0
  source (CodeWeavers, LGPL-2.1-or-later), as published in PhoenicisOrg/winecx. The Sikarugir engine's own
  `winemac.so` exports the same table, so the replacement keeps Apple Metal and DXMT working.

## License

Wine and these patches are LGPL-2.1-or-later. Distributed builds include this source (Wine's tarball + the
patches) and the build script, so the binaries can be rebuilt and replaced.

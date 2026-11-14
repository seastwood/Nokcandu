#!/bin/bash
# Build only Wine 11.0's Unix controller bus, retaining SDL and stock Windows modules.
# SDL2_LIBRARY_DIR=/path/to/engine/Contents/Frameworks Engine/controller-hid/build.sh
# Requires cached checksum-pinned Wine/build tools from Engine/winemac/build.sh and SDL2 headers.
set -euo pipefail
cd "$(dirname "$0")/../.."
hidRoot="$(pwd)"
hidCache="$hidRoot/build/winemac-work"
hidWork="$hidRoot/build/controller-hid-work"
hidOut="${1:-$hidRoot/build/controller-hid-11.0}"
case "$hidOut" in /*) ;; *) hidOut="$hidRoot/$hidOut";; esac
hidCompiler=llvm-mingw-20261006-ucrt-macos-universal
hidArchive="$hidCache/wine-11.0.tar.xz"
hidExpected="$(cat Engine/winemac/checksums/wine-11.0.sha256)"
[ "$(shasum -a 256 "$hidArchive" | cut -d' ' -f1)" = "$hidExpected" ] || { echo 'Pinned Wine source is missing or changed.' >&2; exit 1; }
for hidTool in "$hidCache/tools/bin/bison" "$hidCache/$hidCompiler/bin/clang"; do
    [ -x "$hidTool" ] || { echo 'Prepare pinned Wine build tools first.' >&2; exit 1; }
done
: "${SDL2_LIBRARY_DIR:?Set SDL2_LIBRARY_DIR to the source engine Frameworks directory}"
source "$hidRoot/Engine/controller-hid/sdl-runtime.sh"
nokcandu_controller_sdl_runtime "$SDL2_LIBRARY_DIR"
export SDL2_CFLAGS="${SDL2_CFLAGS:--I/opt/homebrew/include/SDL2}"
# Keep each complete source/patch set isolated; overlapping patches cannot be
# reverse-probed one by one after later patches change their context.
# The emulated controllers' protocol is Nokcandu's shared virtual-controller core (also used on the Mac).
hidShared=("$hidRoot/Sources/NokcanduPadEngine/virtualpad.c" "$hidRoot/Sources/NokcanduPadEngine/include/virtualpad.h")
hidInputs="$(cat "$hidRoot"/Engine/controller-hid/000*.patch "$hidRoot"/Engine/controller-hid/*.h "${hidShared[@]}" | shasum -a 256 | cut -d' ' -f1)"
hidSourceRoot="$hidWork/source-$hidInputs"
hidObjects="$hidWork/obj-$hidInputs"
mkdir -p "$hidSourceRoot" "$hidObjects" "$hidOut"
# Avoid spaces in configure's linker arguments without changing any engine files.
hidLink="$(mktemp -d /tmp/nokcandu-hid-link.XXXXXX)"
trap 'rm -f "$hidLink/frameworks"; rmdir "$hidLink"' EXIT
ln -s "$SDL2_LIBRARY_DIR" "$hidLink/frameworks"
export SDL2_LIBS="-L$hidLink/frameworks -lSDL2-2.0.0" ac_cv_lib_soname_SDL2="$NOKCANDU_CONTROLLER_SDL_NAME"
hidSource="$hidSourceRoot/wine-11.0"
[ -f "$hidSource/configure" ] || tar xf "$hidArchive" -C "$hidSourceRoot"
hidStamp="$hidSourceRoot/applied-source.sha256"
if [ -f "$hidStamp" ]; then
    [ "$(shasum -a 256 "$hidSource/dlls/winebus.sys/bus_iohid.c" | cut -d' ' -f1)" = "$(cat "$hidStamp")" ] || { echo 'Generated controller source was edited; preserved unchanged.' >&2; exit 1; }
else
    for hidPatch in "$hidRoot"/Engine/controller-hid/000*.patch; do
        patch --force --dry-run --silent -p1 -d "$hidSource" < "$hidPatch" >/dev/null 2>&1 || { echo 'Conflicting source edits; preserved unchanged.' >&2; exit 1; }
        patch --force --silent -p1 -d "$hidSource" < "$hidPatch"
    done
    shasum -a 256 "$hidSource/dlls/winebus.sys/bus_iohid.c" | cut -d' ' -f1 > "$hidStamp"
fi
for hidHeader in "$hidRoot"/Engine/controller-hid/*.h "${hidShared[@]}"; do
    hidCopy="$hidSource/dlls/winebus.sys/$(basename "$hidHeader")"
    if [ -f "$hidCopy" ]; then cmp -s "$hidHeader" "$hidCopy" || { echo 'Generated controller header was edited; preserved unchanged.' >&2; exit 1; }
    else cp "$hidHeader" "$hidCopy"; fi
done
export PATH="$hidCache/tools/bin:$hidCache/$hidCompiler/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd "$hidObjects"
# Reconfigure so SDL library/header changes cannot silently reuse a no-SDL build.
arch -x86_64 "$hidSource/configure" --enable-archs=i386,x86_64 --with-mingw="$hidCache/$hidCompiler/bin/clang" \
    --without-x --without-freetype --without-gstreamer --without-vulkan --without-opencl --without-pcap --with-sdl \
    --without-cups --without-gnutls --without-unwind --without-usb --without-pcsclite \
    CC='/usr/bin/clang -arch x86_64' CFLAGS='-O2 -g' > configure.log 2>&1 || { tail -25 configure.log; exit 1; }
grep -q '^#define HAVE_SDL_H 1' include/config.h || { echo 'SDL headers were not detected; refusing incomplete bus.' >&2; exit 1; }
grep -q '^#define SONAME_LIBSDL2 "libSDL2-2.0.0.dylib"' include/config.h || { echo 'The original engine SDL runtime was not selected.' >&2; exit 1; }
arch -x86_64 make -j8 dlls/winebus.sys/winebus.so > make.log 2>&1 || { tail -30 make.log; exit 1; }
hidStage="$(mktemp "$hidOut/winebus.so.XXXXXX")"
cp dlls/winebus.sys/winebus.so "$hidStage"
mv -f "$hidStage" "$hidOut/winebus.so"
printf '{"version":"11.0","sourceSHA256":"%s","stockSHA256":["ebe0cc57211eca3474a39acabe5d2faaacd6bb19b7e758a7701e33cb38f14d19"]}\n' "$(shasum -a 256 "$hidOut/winebus.so" | cut -d' ' -f1)" > "$hidOut/manifest.json"
cp "$hidSource/COPYING.LIB" "$hidOut/"
printf '%s\n' "$hidExpected" > "$hidOut/wine-source.sha256"
cat "$hidRoot"/Engine/controller-hid/000*.patch "$hidRoot"/Engine/controller-hid/*.h "${hidShared[@]}" | shasum -a 256 | cut -d' ' -f1 > "$hidOut/nokcandu-patch.sha256"
echo "Built full-SDL Wine 11.0 controller bus into $hidOut"

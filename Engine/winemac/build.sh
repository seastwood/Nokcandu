#!/bin/bash
# Builds Nokcandu's Wine Mac driver (winemac.so + winemac.drv for x86_64 and i386) from Wine's own source plus
# the patches in patches/, for dropping into a Sikarugir engine of the same Wine version (SUPPORTED_WINE).
#
#   Engine/winemac/build.sh [output-dir]      (default: build/winemac)
#
# WINE_VERSION=11.0 WINEMAC_TRY=1 Engine/winemac/build.sh /tmp/out tries the patches on another Wine version
# (its source isn't checksummed yet in that mode): the engine watcher uses it when Sikarugir moves to a newer Wine.
#
# Needs Xcode's command line tools. Downloads (once, checksummed) into build/winemac-work: the Wine 10.0
# source, GNU Bison 3.8.2 (Wine needs a newer one than macOS ships) and llvm-mingw (Wine builds its Windows
# side with it, like Wine's own macOS builds).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
OUT_ARG="${1:-}"
WORK="$ROOT/build/winemac-work"
WINE_VERSION="${WINE_VERSION:-$(head -1 "$ROOT/Engine/winemac/SUPPORTED_WINE")}"
WINE_DIR="${WINE_VERSION%%.*}.$( [ "${WINE_VERSION#*.}" = 0 ] && echo 0 || echo x )"
BISON=bison-3.8.2; LLVM_MINGW=llvm-mingw-20261006-ucrt-macos-universal
OUT="${OUT_ARG:-$ROOT/build/winemac-$WINE_VERSION}"
mkdir -p "$WORK" "$OUT"; cd "$WORK"

fetch() {   # url file sha256
    [ -f "$2" ] || curl -fsSL -o "$2.part" "$1" && { [ -f "$2" ] || mv "$2.part" "$2"; }
    local got; got=$(shasum -a 256 "$2" | cut -d' ' -f1)
    [ "$got" = "$3" ] || { echo "Checksum mismatch for $2: $got"; exit 1; }
}
if [ -f "$ROOT/Engine/winemac/checksums/wine-$WINE_VERSION.sha256" ]; then
    fetch "https://dl.winehq.org/wine/source/$WINE_DIR/wine-$WINE_VERSION.tar.xz" "wine-$WINE_VERSION.tar.xz" "$(cat "$ROOT/Engine/winemac/checksums/wine-$WINE_VERSION.sha256")"
elif [ "${WINEMAC_TRY:-0}" = 1 ]; then
    [ -f "wine-$WINE_VERSION.tar.xz" ] || curl -fsSL -o "wine-$WINE_VERSION.tar.xz" "https://dl.winehq.org/wine/source/$WINE_DIR/wine-$WINE_VERSION.tar.xz"
    echo "Wine $WINE_VERSION source (not yet pinned): $(shasum -a 256 "wine-$WINE_VERSION.tar.xz" | cut -d' ' -f1)"
else
    echo "Wine $WINE_VERSION isn't pinned in Engine/winemac/checksums (use WINEMAC_TRY=1 to try it)."; exit 1
fi
fetch "https://ftp.gnu.org/gnu/bison/$BISON.tar.xz" "$BISON.tar.xz" "$(cat "$ROOT/Engine/winemac/checksums/$BISON.sha256")"
fetch "https://github.com/mstorsjo/llvm-mingw/releases/download/20261006/$LLVM_MINGW.tar.xz" "$LLVM_MINGW.tar.xz" "$(cat "$ROOT/Engine/winemac/checksums/$LLVM_MINGW.sha256")"

if [ ! -x tools/bin/bison ]; then
    rm -rf "$BISON"; tar xf "$BISON.tar.xz"
    (cd "$BISON" && ./configure --prefix="$WORK/tools" >/dev/null 2>&1 && make -j8 >/dev/null 2>&1 && make install >/dev/null 2>&1)
fi
[ -d "$LLVM_MINGW" ] || tar xf "$LLVM_MINGW.tar.xz"
export PATH="$WORK/tools/bin:$PATH:$WORK/$LLVM_MINGW/bin"

# Fresh source with our patches, every time (the patches are the whole difference from Wine 10.0).
# One source and build folder per Wine version (10.0 keeps the original names).
SRC=src OBJ=obj; [ "$WINE_VERSION" = 10.0 ] || { SRC="src-$WINE_VERSION"; OBJ="obj-$WINE_VERSION"; }
rm -rf "$SRC"; mkdir "$SRC"; tar xf "wine-$WINE_VERSION.tar.xz" -C "$SRC"
# Each Wine version has its own port of the patches (patches/ is Wine 10.0's). Trying a version with none yet uses
# the newest port.
PATCHES="$ROOT/Engine/winemac/patches-$WINE_VERSION"
[ "$WINE_VERSION" = 10.0 ] && PATCHES="$ROOT/Engine/winemac/patches"
[ -d "$PATCHES" ] || PATCHES="$(ls -d "$ROOT"/Engine/winemac/patches-* 2>/dev/null | sort -V | tail -1)"
[ -d "$PATCHES" ] || PATCHES="$ROOT/Engine/winemac/patches"
echo "Patches: ${PATCHES#$ROOT/}"
for p in "$PATCHES"/*.patch; do
    (cd "$SRC/wine-$WINE_VERSION" && patch -p1 --quiet < "$p") || { echo "PATCH FAILED: $(basename "$p") on Wine $WINE_VERSION"; exit 2; }
done

mkdir -p "$OBJ"; cd "$OBJ"
if [ ! -f Makefile ]; then
    arch -x86_64 ../$SRC/wine-$WINE_VERSION/configure --enable-archs=i386,x86_64 --with-mingw="$WORK/$LLVM_MINGW/bin/clang" \
        --without-x --without-freetype --without-gstreamer --without-vulkan --without-opencl --without-pcap --without-sdl \
        --without-cups --without-gnutls --without-unwind --without-usb --without-pcsclite \
        CC="/usr/bin/clang -arch x86_64" CFLAGS="-O2 -g" > configure.log 2>&1 || { tail -20 configure.log; exit 1; }
fi
arch -x86_64 make -j8 dlls/winemac.drv/winemac.so dlls/winemac.drv/x86_64-windows/winemac.drv dlls/winemac.drv/i386-windows/winemac.drv > make.log 2>&1 \
    || { grep -E " error" make.log | head -20; exit 1; }
mkdir -p "$OUT/x86_64-unix" "$OUT/x86_64-windows" "$OUT/i386-windows"
cp dlls/winemac.drv/winemac.so "$OUT/x86_64-unix/"
cp dlls/winemac.drv/x86_64-windows/winemac.drv "$OUT/x86_64-windows/"
cp dlls/winemac.drv/i386-windows/winemac.drv "$OUT/i386-windows/"
echo "$WINE_VERSION" > "$OUT/wine-version"      # which engines this driver goes into (Wine major.minor)
( cd "$OUT" && shasum -a 256 */winemac.* > SHA256SUMS )
echo "Built into $OUT"; cat "$OUT/SHA256SUMS"

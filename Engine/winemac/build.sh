#!/bin/bash
# Builds Nokcandu's Wine Mac driver (winemac.so + winemac.drv for x86_64 and i386) from Wine's own source plus
# the patches in patches/, for dropping into a Sikarugir Wine 10.0 engine.
#
#   Engine/winemac/build.sh [output-dir]      (default: build/winemac)
#
# Needs Xcode's command line tools. Downloads (once, checksummed) into build/winemac-work: the Wine 10.0
# source, GNU Bison 3.8.2 (Wine needs a newer one than macOS ships) and llvm-mingw (Wine builds its Windows
# side with it, like Wine's own macOS builds).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
OUT="${1:-$ROOT/build/winemac}"
WORK="$ROOT/build/winemac-work"
WINE_VERSION=10.0
BISON=bison-3.8.2; LLVM_MINGW=llvm-mingw-20261006-ucrt-macos-universal
mkdir -p "$WORK" "$OUT"; cd "$WORK"

fetch() {   # url file sha256
    [ -f "$2" ] || curl -fsSL -o "$2.part" "$1" && { [ -f "$2" ] || mv "$2.part" "$2"; }
    local got; got=$(shasum -a 256 "$2" | cut -d' ' -f1)
    [ "$got" = "$3" ] || { echo "Checksum mismatch for $2: $got"; exit 1; }
}
fetch "https://dl.winehq.org/wine/source/10.0/wine-$WINE_VERSION.tar.xz" "wine-$WINE_VERSION.tar.xz" "$(cat "$ROOT/Engine/winemac/checksums/wine-$WINE_VERSION.sha256")"
fetch "https://ftp.gnu.org/gnu/bison/$BISON.tar.xz" "$BISON.tar.xz" "$(cat "$ROOT/Engine/winemac/checksums/$BISON.sha256")"
fetch "https://github.com/mstorsjo/llvm-mingw/releases/download/20261006/$LLVM_MINGW.tar.xz" "$LLVM_MINGW.tar.xz" "$(cat "$ROOT/Engine/winemac/checksums/$LLVM_MINGW.sha256")"

if [ ! -x tools/bin/bison ]; then
    rm -rf "$BISON"; tar xf "$BISON.tar.xz"
    (cd "$BISON" && ./configure --prefix="$WORK/tools" >/dev/null && make -j8 >/dev/null && make install >/dev/null)
fi
[ -d "$LLVM_MINGW" ] || tar xf "$LLVM_MINGW.tar.xz"
export PATH="$WORK/tools/bin:$PATH:$WORK/$LLVM_MINGW/bin"

# Fresh source with our patches, every time (the patches are the whole difference from Wine 10.0).
rm -rf src; mkdir src; tar xf "wine-$WINE_VERSION.tar.xz" -C src
for p in "$ROOT"/Engine/winemac/patches/*.patch; do (cd "src/wine-$WINE_VERSION" && patch -p1 --quiet < "$p"); done

mkdir -p obj; cd obj
if [ ! -f Makefile ]; then
    arch -x86_64 ../src/wine-$WINE_VERSION/configure --enable-archs=i386,x86_64 --with-mingw="$WORK/$LLVM_MINGW/bin/clang" \
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
( cd "$OUT" && shasum -a 256 */winemac.* > SHA256SUMS )
echo "Built into $OUT"; cat "$OUT/SHA256SUMS"

#!/bin/bash
# Builds Nokcandu's Wine Mac driver for MetalSharp Wine (Apple silicon), as winenokmac.drv / winenokmac.so:
# MetalSharp's own Mac driver source (Wine 11.20 + MetalSharp, the commit its release was built from) plus
# patches-metalsharp-<release>/. It never goes into the engine (which is signed and must stay as it is): Nokcandu
# puts it beside the engine and selects it with WINEDLLPATH and the Graphics driver setting (ExternalDriver.swift).
#
#   Engine/winemac/build-metalsharp.sh [release] [output-dir]   (default: 8.0, build/winenokmac-metalsharp-<release>)
#
# Needs Xcode's command line tools and an Apple silicon Mac. Downloads (once) into build/winemac-work: the Wine
# source from MetalSharp's repository at the pinned commit, GNU Bison 3.8.2 and llvm-mingw (checksummed).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
RELEASE="${1:-8.0}"
OUT="${2:-$ROOT/build/winenokmac-metalsharp-$RELEASE}"
WORK="$ROOT/build/winemac-work"
PATCHES="$ROOT/Engine/winemac/patches-metalsharp-$RELEASE"
COMMIT="$(cat "$PATCHES/wine-commit")"          # MetalSharp-Wine's src/wine submodule at that release's tag
REPO=https://github.com/metalsharp/MetalSharp-Wine.git
BISON=bison-3.8.2; LLVM_MINGW=llvm-mingw-20261006-ucrt-macos-universal
mkdir -p "$WORK" "$OUT"; cd "$WORK"

fetch() {   # url file sha256
    [ -f "$2" ] || curl -fsSL -o "$2.part" "$1" && { [ -f "$2" ] || mv "$2.part" "$2"; }
    local got; got=$(shasum -a 256 "$2" | cut -d' ' -f1)
    [ "$got" = "$3" ] || { echo "Checksum mismatch for $2: $got"; exit 1; }
}
fetch "https://ftp.gnu.org/gnu/bison/$BISON.tar.xz" "$BISON.tar.xz" "$(cat "$ROOT/Engine/winemac/checksums/$BISON.sha256")"
fetch "https://github.com/mstorsjo/llvm-mingw/releases/download/20261006/$LLVM_MINGW.tar.xz" "$LLVM_MINGW.tar.xz" "$(cat "$ROOT/Engine/winemac/checksums/$LLVM_MINGW.sha256")"
if [ ! -x tools/bin/bison ]; then
    rm -rf "$BISON"; tar xf "$BISON.tar.xz"
    (cd "$BISON" && ./configure --prefix="$WORK/tools" >/dev/null 2>&1 && make -j8 >/dev/null 2>&1 && make install >/dev/null 2>&1)
fi
[ -d "$LLVM_MINGW" ] || tar xf "$LLVM_MINGW.tar.xz"
export PATH="$WORK/tools/bin:$PATH:$WORK/$LLVM_MINGW/bin"

# The source at the pinned commit (a git checkout, so the commit is verified by its hash), then our patches.
SRC="$WORK/src-metalsharp-$RELEASE"
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" != "$COMMIT" ]; then
    rm -rf "$SRC"; mkdir -p "$SRC"
    git -C "$SRC" init -q
    git -C "$SRC" fetch -q --depth 1 "$REPO" "$COMMIT"
    git -C "$SRC" checkout -q FETCH_HEAD
fi
git -C "$SRC" reset -q --hard "$COMMIT"; git -C "$SRC" clean -qfdx dlls/winemac.drv
for p in "$PATCHES"/*.patch; do
    git -C "$SRC" apply "$p" || { echo "PATCH FAILED: $(basename "$p")"; exit 2; }
done
cp "$ROOT/Engine/winemac/controller-mouse-button.h" "$SRC/dlls/winemac.drv/"

OBJ="$WORK/obj-metalsharp-$RELEASE"
mkdir -p "$OBJ"; cd "$OBJ"
if [ ! -f Makefile ]; then
    "$SRC/configure" --enable-archs=arm64ec,aarch64,i386 --with-mingw="$WORK/$LLVM_MINGW/bin/clang" \
        --without-x --without-wayland --without-freetype --without-gstreamer --without-vulkan --without-opencl \
        --without-pcap --without-sdl --without-cups --without-gnutls --without-unwind --without-usb --without-pcsclite \
        --without-ffmpeg --without-gettext --without-gettextpo \
        CC="/usr/bin/clang -arch arm64" OBJC="/usr/bin/clang -arch arm64" CFLAGS="-O2 -g -mmacosx-version-min=15.0" \
        OBJCFLAGS="-O2 -g -mmacosx-version-min=15.0" LDFLAGS="-mmacosx-version-min=15.0" > configure.log 2>&1 \
        || { tail -30 configure.log; exit 1; }
fi
make -k -j8 dlls/winemac.drv/winenokmac.so dlls/winemac.drv/aarch64-windows/winenokmac.drv \
    dlls/winemac.drv/i386-windows/winenokmac.drv > make.log 2>&1 || { grep -E " error|Error " make.log | head -30; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT/aarch64-unix" "$OUT/aarch64-windows" "$OUT/i386-windows"
cp dlls/winemac.drv/winenokmac.so "$OUT/aarch64-unix/"
cp dlls/winemac.drv/aarch64-windows/winenokmac.drv "$OUT/aarch64-windows/"
cp dlls/winemac.drv/i386-windows/winenokmac.drv "$OUT/i386-windows/"
echo "metalsharp $RELEASE" > "$OUT/engine"
sed -n 's/^Wine version \([0-9]*\.[0-9]*\).*/\1/p' "$SRC/VERSION" > "$OUT/wine-version"   # where Nokcandu files it
bash "$ROOT/Engine/winemac/server-requests.sh" "$SRC" > "$OUT/server-requests"
( cd "$OUT" && shasum -a 256 */winenokmac.* > SHA256SUMS )
echo "Built into $OUT"; cat "$OUT/SHA256SUMS"

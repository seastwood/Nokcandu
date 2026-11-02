#!/bin/bash
# Build Wine's missing native packet-capture module, separately from the Mac graphics driver.
# WINE_VERSION=11.0 Engine/wpcap/build.sh [output-dir]
# Reuses the checksum-pinned Wine/Bison/llvm-mingw downloads prepared by Engine/winemac/build.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
packetRoot="$(pwd)"
packetVersion="${WINE_VERSION:-11.0}"
case "$packetVersion" in 10.0|11.0) ;; *) echo 'Packet support is only built against the pinned Wine 10.0/11.0 sources.' >&2; exit 1;; esac
packetWork="$packetRoot/build/wpcap-work"
packetCache="$packetRoot/build/winemac-work"
packetOutput="${1:-$packetRoot/build/wpcap-$packetVersion}"
case "$packetOutput" in /*) ;; *) packetOutput="$packetRoot/$packetOutput";; esac
packetCompiler=llvm-mingw-20261006-ucrt-macos-universal
for item in "$packetCache/tools/bin/bison" "$packetCache/$packetCompiler/bin/clang"; do
    [ -x "$item" ] || { echo 'Prepare the pinned build tools with Engine/winemac/build.sh first.' >&2; exit 1; }
done
packetArchive="$packetCache/wine-$packetVersion.tar.xz"
[ -f "$packetArchive" ] || { echo 'The pinned Wine source archive is missing; prepare Engine/winemac/build.sh first.' >&2; exit 1; }
packetExpected="$(cat "$packetRoot/Engine/winemac/checksums/wine-$packetVersion.sha256")"
[ "$(shasum -a 256 "$packetArchive" | cut -d' ' -f1)" = "$packetExpected" ] || { echo 'Wine source checksum mismatch.' >&2; exit 1; }
mkdir -p "$packetWork/source-$packetVersion" "$packetWork/obj-$packetVersion" "$packetOutput"
if [ ! -f "$packetWork/source-$packetVersion/wine-$packetVersion/configure" ]; then
    tar xf "$packetArchive" -C "$packetWork/source-$packetVersion"
fi
# Refuse partially applied or different local edits; apply the complete pinned patch once.
packetSource="$packetWork/source-$packetVersion/wine-$packetVersion"
packetPatch="$packetRoot/Engine/wpcap/native-capture-$packetVersion.patch"
if patch --force --dry-run --silent -R -p1 -d "$packetSource" < "$packetPatch" >/dev/null 2>&1; then
    : # Already applied.
elif patch --force --dry-run --silent -p1 -d "$packetSource" < "$packetPatch" >/dev/null 2>&1; then
    patch --force --silent -p1 -d "$packetSource" < "$packetPatch"
else
    echo 'Packet source contains conflicting changes; use a fresh source directory.' >&2; exit 1
fi
export PATH="$packetCache/tools/bin:$packetCache/$packetCompiler/bin:$PATH"
cd "$packetWork/obj-$packetVersion"
if [ -f Makefile ] && ! grep -Fq "srcdir = $packetSource" Makefile; then
    echo 'Packet build points at another source tree; choose a fresh object directory.' >&2; exit 1
fi
if [ ! -f Makefile ]; then
    arch -x86_64 "$packetWork/source-$packetVersion/wine-$packetVersion/configure" \
        --enable-archs=i386,x86_64 --with-mingw="$packetCache/$packetCompiler/bin/clang" --with-pcap \
        --without-x --without-freetype --without-gstreamer --without-vulkan --without-opencl --without-sdl \
        --without-cups --without-gnutls --without-unwind --without-usb --without-pcsclite \
        CC='/usr/bin/clang -arch x86_64' CFLAGS='-O2 -g' > configure.log 2>&1 || { tail -25 configure.log; exit 1; }
fi
# A stale --without-pcap build is not suitable: do not silently package a nonfunctional module.
grep -q '^#define HAVE_PCAP_PCAP_H 1' include/config.h || { echo 'Native libpcap headers were not detected.' >&2; exit 1; }
arch -x86_64 make -j8 dlls/wpcap/wpcap.so dlls/wpcap/i386-windows/wpcap.dll dlls/wpcap/x86_64-windows/wpcap.dll > make.log 2>&1 \
    || { tail -30 make.log; exit 1; }
mkdir -p "$packetOutput/i386-windows" "$packetOutput/x86_64-windows" "$packetOutput/x86_64-unix"
# Atomic replacement preserves the inode of modules held by an earlier test.
for packetMember in i386-windows/wpcap.dll x86_64-windows/wpcap.dll x86_64-unix/wpcap.so; do
    packetInput="dlls/wpcap/$packetMember"
    [ "$packetMember" != x86_64-unix/wpcap.so ] || packetInput=dlls/wpcap/wpcap.so
    packetStage="$(mktemp "$packetOutput/$packetMember.XXXXXX")"
    cp "$packetInput" "$packetStage"
    mv -f "$packetStage" "$packetOutput/$packetMember"
done
"$packetCache/$packetCompiler/bin/i686-w64-mingw32-clang" -O2 -Wall -Wextra -Werror "$packetRoot/Engine/wpcap/adapter-info.c" -liphlpapi -o "$packetOutput/adapter-info.exe"
printf '%s\n' "$packetVersion" > "$packetOutput/wine-version"
printf '%s\n' "$packetExpected" > "$packetOutput/wine-source.sha256"
shasum -a 256 "$packetPatch" | cut -d' ' -f1 > "$packetOutput/nokcandu-patch.sha256"
(cd "$packetOutput" && shasum -a 256 i386-windows/wpcap.dll x86_64-windows/wpcap.dll x86_64-unix/wpcap.so adapter-info.exe > SHA256SUMS)
echo "Built packet-capture module for Wine $packetVersion into $packetOutput"

#!/bin/bash
# Reproducible Windows helpers. ZIG may point at an existing official Zig 0.15.2 installation.
set -euo pipefail
cd "$(dirname "$0")"
if [ -z "${ZIG:-}" ]; then
 case "$(uname -m)" in
  arm64) ARCH=aarch64; SHA=3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b ;;
  x86_64) ARCH=x86_64; SHA=375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f ;;
  *) echo 'Unsupported build host'; exit 1 ;;
 esac
 CACHE="${TMPDIR:-/tmp}/nokcandu-zig-0.15.2"
 mkdir -p "$CACHE"
 if [ ! -x "$CACHE/zig-$ARCH-macos-0.15.2/zig" ]; then
  curl -fL --retry 2 "https://ziglang.org/download/0.15.2/zig-$ARCH-macos-0.15.2.tar.xz" -o "$CACHE/zig.tar.xz"
  echo "$SHA  $CACHE/zig.tar.xz" | shasum -a 256 -c -
  tar -xf "$CACHE/zig.tar.xz" -C "$CACHE"
 fi
 ZIG="$CACHE/zig-$ARCH-macos-0.15.2/zig"
fi
DEST="${1:?Destination folder required}"
mkdir -p "$DEST"
for arch in x86 x86_64; do
 "$ZIG" cc -target "$arch-windows-gnu" -Os -s launcher.c -o "$DEST/borderless-$arch.exe" -luser32 -Wl,--subsystem,windows
 "$ZIG" cc -target "$arch-windows-gnu" -Os -s -shared window.c -o "$DEST/borderless-$arch.dll" -luser32
 done

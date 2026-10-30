#!/bin/bash
# Builds the stand-in Windows "Bonjour Service" (bonjour-service.c) with llvm-mingw. The result is kept in this
# folder (nokcandu-bonjour-service.exe), so building Nokcandu doesn't need the Windows toolchain.
set -e
cd "$(dirname "$0")"
CC="${MINGW_CC:-$(ls -d ../../build/winemac-work/llvm-mingw-*/bin 2>/dev/null | head -1)/x86_64-w64-mingw32-clang}"
"$CC" -O2 -s -municode -o nokcandu-bonjour-service.exe bonjour-service.c -ladvapi32
shasum -a 256 nokcandu-bonjour-service.exe

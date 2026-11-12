#!/bin/bash
# Prepare the full-SDL controller bus on a fresh CI runner. Downloads stay in build/.
set -euo pipefail
cd "$(dirname "$0")/../.."
WINE_VERSION=11.0 bash Engine/winemac/build.sh
if [ -z "${SDL2_LIBRARY_DIR:-}" ]; then
  controllerCache="$PWD/build/controller-hid-runtime"
  controllerArchive="$controllerCache/Template-1.0.24.tar.xz"
  mkdir -p "$controllerCache"
  controllerSHA=4b5f89eeb9ef139936bdfad33d9b420b05ea4597cb7d63376674f7a8e171321c
  if [ ! -f "$controllerArchive" ]; then
    curl --fail --location --retry 3 'https://github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.24.tar.xz' -o "$controllerArchive.part"
    mv "$controllerArchive.part" "$controllerArchive"
  fi
  [ "$(shasum -a 256 "$controllerArchive" | cut -d' ' -f1)" = "$controllerSHA" ] || { echo 'Controller runtime checksum mismatch' >&2; exit 1; }
  controllerExtract="$(mktemp -d "$controllerCache/extracted.XXXXXX")"
  tar -xJf "$controllerArchive" -C "$controllerExtract"
  SDL2_LIBRARY_DIR="$(find "$controllerExtract" -type d -name Frameworks -print -quit)"
  [ -n "$SDL2_LIBRARY_DIR" ] || { echo 'Controller runtime Frameworks missing' >&2; exit 1; }
  export SDL2_LIBRARY_DIR
fi
if [ -z "${SDL2_CFLAGS:-}" ]; then
  brew list sdl2 >/dev/null 2>&1 || brew install sdl2
  export SDL2_CFLAGS="-I$(brew --prefix sdl2)/include/SDL2"
fi
bash Engine/controller-hid/build.sh

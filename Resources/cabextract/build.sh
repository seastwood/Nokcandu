#!/bin/bash
# cabextract 1.11 (GPL-3.0-or-later); official source, built for this Mac/CI host.
set -euo pipefail
DEST="${1:?Destination folder required}"
CACHE="${TMPDIR:-/tmp}/nokcandu-cabextract-1.11-$(uname -m)"
mkdir -p "$CACHE" "$DEST"
if [ ! -x "$CACHE/cabextract-1.11/cabextract" ]; then
 curl -fL --retry 2 https://www.cabextract.org.uk/cabextract-1.11.tar.gz -o "$CACHE/source.tar.gz"
 echo "b5546db1155e4c718ff3d4b278573604f30dd64c3c5bfd4657cd089b823a3ac6  $CACHE/source.tar.gz" | shasum -a 256 -c -
 tar -xf "$CACHE/source.tar.gz" -C "$CACHE"
 (cd "$CACHE/cabextract-1.11"; ./configure --disable-dependency-tracking; make -j2)
fi
cp "$CACHE/cabextract-1.11/cabextract" "$DEST/cabextract"
cp "$CACHE/cabextract-1.11/COPYING" "$DEST/cabextract-COPYING.txt"

# Ship the exact corresponding source and build recipe alongside the independent GPL tool.
cp "$CACHE/source.tar.gz" "$DEST/cabextract-source.tar.gz"
cp "$0" "$DEST/cabextract-build.sh"

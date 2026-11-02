#!/bin/bash
# Package corresponding source separately from the app; never commit runtime/source archives.
set -euo pipefail
cd "$(dirname "$0")/../.."
packetVersion="$(tr -d '[:space:]' < VERSION)"
packetArchive=build/winemac-work/wine-11.0.tar.xz
packetExpected="$(cat Engine/winemac/checksums/wine-11.0.sha256)"
[ "$(shasum -a 256 "$packetArchive" | cut -d' ' -f1)" = "$packetExpected" ] || { echo 'Wine source checksum mismatch.' >&2; exit 1; }
packetSourceStage="$(mktemp -d)"
trap 'rm -rf "$packetSourceStage"' EXIT
mkdir -p "$packetSourceStage/build/winemac-work" "$packetSourceStage/Engine"
cp "$packetArchive" "$packetSourceStage/build/winemac-work/"
cp -R Engine/winemac Engine/wpcap "$packetSourceStage/Engine/"
cp VERSION Resources/native-ipx/COPYING.LIB "$packetSourceStage/"
cat > "$packetSourceStage/README.txt" <<'TXT'
Wine 11 native packet-capture module corresponding source

The pinned upstream Wine source archive includes the full library source.
Engine/wpcap contains Nokcandu's version-matched patches and build script.
Engine/winemac contains the pinned compiler/Bison preparation and checksums.

On an Apple Silicon Mac with the Xcode command-line tools:
  WINE_VERSION=11.0 bash Engine/winemac/build.sh
  WINE_VERSION=11.0 bash Engine/wpcap/build.sh

This produces replaceable PE and Unix module files under build/wpcap-11.0.
COPYING.LIB and the source headers contain the applicable license/notices.
TXT
packetSourceOutput="build/Nokcandu-native-ipx-source-$packetVersion.tar.gz"
tar -czf "$packetSourceOutput" -C "$packetSourceStage" .
shasum -a 256 "$packetSourceOutput" > "$packetSourceOutput.sha256"
echo "Packaged $packetSourceOutput"

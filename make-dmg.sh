#!/bin/bash
# Builds Nokcandu.app (release) and packages it as build/Nokcandu-<version>.dmg (+ .sha256).
#   ./make-dmg.sh            build, test and package
#   SKIP_TESTS=1 ./make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(tr -d '[:space:]' < VERSION)"
if [ "${SKIP_TESTS:-0}" = 1 ]; then ./build-app.sh; else ./build-app.sh --test; fi
STAGE="$(mktemp -d)/Nokcandu"
mkdir -p "$STAGE"
ditto build/Nokcandu.app "$STAGE/Nokcandu.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/First open — read me.txt" <<'TXT'
Installing Nokcandu
1. Drag Nokcandu into Applications.
2. Open Nokcandu from Applications.

Nokcandu isn't signed with a paid Apple Developer certificate yet, so the first time macOS says it
"can't verify" Nokcandu. To open it anyway:
  • Click Done (not Move to Trash).
  • Open System Settings → Privacy & Security, scroll down, and click "Open Anyway" next to Nokcandu.
  • Confirm with your password or Touch ID.
You only need to do this once. Nokcandu updates itself after that.

Requirements: a Mac with Apple silicon (M1 or later), macOS 14 or newer. Nokcandu installs Rosetta 2
and downloads its Wine engine on first launch (about 260 MB).

Source code, help and updates: https://github.com/seastwood/Nokcandu
TXT
DMG="build/Nokcandu-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Nokcandu $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs APFS "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"
# Notarize when Apple credentials are available (Developer ID builds); otherwise the DMG is left as is.
if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ] && [ -n "${NOKCANDU_SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$NOKCANDU_SIGN_IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
  xcrun stapler staple "$DMG"
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Packaged $(pwd)/$DMG"

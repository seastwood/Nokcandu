#!/bin/bash
# Builds build/Nokcandu.app from this Swift package (needs Xcode or the Command Line Tools).
#   ./build-app.sh            build only
#   ./build-app.sh --install  also copy to ~/Applications/Nokcandu.app
#   ./build-app.sh --test     run unit tests first
set -euo pipefail
cd "$(dirname "$0")"
# Development only: `touch .run` (with .rebuild) runs ./run.sh instead of building; output in run.log.
if [ -e .run ]; then rm -f .run; { echo "== $(date)"; /bin/bash ./run.sh; echo "EXIT=$?"; } > run.log 2>&1; exit 0; fi
# Development only: `touch .sample` to capture what a running Nokcandu is doing (sample.txt) instead of building.
if [ -e .sample ]; then rm -f .sample; /usr/bin/sample Nokcandu 2 -file sample.txt >/dev/null 2>&1 || true; exit 0; fi

# Development only: `touch .install-agent` to run the watcher at login (launchd) instead of a Terminal window.
if [ -e .install-agent ]; then
  rm -f .install-agent
  PL="$HOME/Library/LaunchAgents/io.github.seastwood.nokcandu.devwatch.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PL" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.github.seastwood.nokcandu.devwatch</string>
  <key>ProgramArguments</key><array><string>$(pwd)/dev-watch-agent.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>$(pwd)/watch-agent.log</string>
  <key>StandardErrorPath</key><string>$(pwd)/watch-agent.log</string>
</dict></plist>
AGENT
  launchctl bootout "gui/$(id -u)/io.github.seastwood.nokcandu.devwatch" 2>/dev/null || true
  OLD_PL="$HOME/Library/LaunchAgents/local.$(id -un).nokcandu.devwatch.plist"   # earlier dev label
  if [ -f "$OLD_PL" ]; then launchctl bootout "gui/$(id -u)/local.$(id -un).nokcandu.devwatch" 2>/dev/null || true; mv -f "$OLD_PL" "$HOME/.Trash/" 2>/dev/null || true; fi
  launchctl bootstrap "gui/$(id -u)" "$PL" && echo "Installed login watcher: $PL"
fi

if [ "${1:-}" = --test ]; then swift test; shift || true; fi
# Development only: `touch .e2e` to also run the end-to-end install test (creates and removes a test app).
if [ -e .e2e-engine ]; then rm -f .e2e-engine; NOKCANDU_E2E=1 /usr/bin/perl -e "alarm 900; exec @ARGV" swift test --filter "$(cat .e2e-filter 2>/dev/null || echo EngineUpdateE2ETests)" 2>&1 | tee e2e-engine.log || true; /usr/bin/pkill -f "xctest.*E2ETests" || true; fi
if [ -e .e2e ]; then rm -f .e2e; NOKCANDU_E2E=1 /usr/bin/perl -e "alarm 900; exec @ARGV" swift test --filter E2ETests 2>&1 | tee e2e.log || true; /usr/bin/pkill -f "xctest.*E2ETests" || true; fi

swift build -c release --product Nokcandu
swift build -c release --product nokcandu-screen-size
BIN="$(swift build -c release --show-bin-path)"

APP="build/Nokcandu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Nokcandu" "$APP/Contents/MacOS/Nokcandu"
cp "$BIN/nokcandu-screen-size" "$APP/Contents/Resources/screen-size"
cp Resources/bonjour/nokcandu-bonjour-service.exe Resources/refresh-generals-launcher.py Resources/build-icu-adapter.py Resources/generals-launcher "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/Resources/generals-launcher" "$APP/Contents/Resources/screen-size"
./Resources/borderless/build.sh "$(pwd)/$APP/Contents/Resources"
./Resources/cabextract/build.sh "$(pwd)/$APP/Contents/Resources"
# Nokcandu's helper library loaded into Wine: raw mouse, hot corners, game names, sound that follows the Mac's
# devices and Bonjour from the Mac (the resizable window lives in Nokcandu's Wine Mac driver, Engine/winemac).
# Built for both x86_64 (today's Wine runs under Rosetta) and arm64 (a native Wine later) — nothing in it is
# specific to one architecture.
xcrun clang -arch x86_64 -arch arm64 -mmacosx-version-min=11.0 -dynamiclib -fobjc-arc -O2 -Wall \
  -framework AppKit -framework GameController -framework CoreGraphics -framework IOKit -framework OpenGL \
  -framework AudioToolbox -framework CoreAudio \
  -install_name @rpath/nokcandu-rawmouse.dylib \
  -o "$APP/Contents/Resources/nokcandu-rawmouse.dylib" Resources/rawmouse/rawmouse.m Resources/rawmouse/audiofollow.m Resources/rawmouse/bonjourbridge.m
# Nokcandu's Wine Mac driver (resizable game windows): Wine 10.0 + Engine/winemac/patches, built by
# Engine/winemac/build.sh. A fresh local build wins over the copy kept in Resources/winemac.
WINEMAC=Resources/winemac; [ -f build/winemac/SHA256SUMS ] && WINEMAC=build/winemac
if [ "${NOKCANDU_REQUIRE_WINEMAC:-0}" = 1 ] && [ ! -f "$WINEMAC/x86_64-unix/winemac.so" ]; then
  echo "Nokcandu's Wine Mac driver isn't built (Engine/winemac/build.sh): a release needs it."; exit 1
fi
if [ -f "$WINEMAC/x86_64-unix/winemac.so" ]; then
  rm -rf "$APP/Contents/Resources/winemac"; mkdir -p "$APP/Contents/Resources/winemac"
  cp -R "$WINEMAC/x86_64-unix" "$WINEMAC/x86_64-windows" "$WINEMAC/i386-windows" "$APP/Contents/Resources/winemac/"
fi
# Signing identity: a stable one keeps macOS permissions (Input Monitoring, drives, folders) across builds.
# NOKCANDU_SIGN_IDENTITY, else the "Nokcandu Signing" identity from scripts/make-signing-identity.sh, else ad-hoc.
SIGN_ID="${NOKCANDU_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -p codesigning 2>/dev/null | awk '/"Nokcandu Signing"/ { print $2; exit }')"
fi
SIGN_ID="${SIGN_ID:--}"
# Developer ID builds (CI with the Apple secrets) need the hardened runtime and a secure timestamp to notarize.
HARDEN=()
if [ "${NOKCANDU_HARDENED:-0}" = 1 ]; then HARDEN=(--options runtime --timestamp); fi
# The identity's own keychain (scripts/signing-keychain.sh): unlock it so codesign never prompts.
SIGN_KC=()
KC="$HOME/Library/Keychains/nokcandu-signing.keychain-db"
KC_PW="$HOME/Library/Application Support/Nokcandu/signing-keychain.password"
if [ -z "${NOKCANDU_SIGN_IDENTITY:-}" ] && [ -f "$KC" ] && [ -f "$KC_PW" ] && security unlock-keychain -p "$(cat "$KC_PW")" "$KC" 2>/dev/null; then
  K_ID="$(security find-identity -p codesigning "$KC" 2>/dev/null | awk '/"Nokcandu Signing"/ { print $2; exit }')"
  [ -n "$K_ID" ] && { SIGN_ID="$K_ID"; SIGN_KC=(--keychain "$KC"); echo "Signing keychain: nokcandu-signing (unlocked, no prompts)"; }
fi
[ "$SIGN_ID" = "-" ] && echo "Signing: ad-hoc (macOS will re-ask for permissions after each build)" || echo "Signing: $SIGN_ID"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} ${SIGN_KC[@]+"${SIGN_KC[@]}"} --sign "$SIGN_ID" "$APP/Contents/Resources/nokcandu-rawmouse.dylib"
[ -f "$APP/Contents/Resources/winemac/x86_64-unix/winemac.so" ] && codesign --force ${HARDEN[@]+"${HARDEN[@]}"} ${SIGN_KC[@]+"${SIGN_KC[@]}"} --sign "$SIGN_ID" "$APP/Contents/Resources/winemac/x86_64-unix/winemac.so"

codesign --force ${HARDEN[@]+"${HARDEN[@]}"} ${SIGN_KC[@]+"${SIGN_KC[@]}"} --sign "$SIGN_ID" "$APP/Contents/Resources/cabextract"

# App icon (original artwork in Resources/AppIcon.png)
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z $d $d Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "warning: icon not built"

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Nokcandu</string>
  <key>CFBundleIdentifier</key><string>io.github.seastwood.nokcandu</string>
  <key>CFBundleName</key><string>Nokcandu</string>
  <key>CFBundleDisplayName</key><string>Nokcandu</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Battle.net sign-in return (forwarded to Battle.net in Wine)</string>
    <key>CFBundleURLSchemes</key><array><string>battlenet</string><string>blizzard</string></array>
  </dict><dict>
    <key>CFBundleURLName</key><string>Nokcandu game profiles</string>
    <key>CFBundleURLSchemes</key><array><string>nokcandu</string></array>
  </dict></array>
  <key>NSMicrophoneUsageDescription</key><string>Games started from Nokcandu can use your microphone for voice chat.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Nokcandu reads and adjusts some games' settings in your Documents folder.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Nokcandu installs games from installers and disc images you choose in Downloads.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Nokcandu keeps games and game files on drives you choose, like an external SSD.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Nokcandu can install games from a network drive you choose.</string>
</dict>
</plist>
PLIST

# Signed with the identity chosen above (not notarized).
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} ${SIGN_KC[@]+"${SIGN_KC[@]}"} --sign "$SIGN_ID" "$APP/Contents/Resources/screen-size"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} ${SIGN_KC[@]+"${SIGN_KC[@]}"} --sign "$SIGN_ID" "$APP"
echo "Built $(pwd)/$APP"

if [ "${1:-}" = --install ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Nokcandu.app"
  cp -R "$APP" "$HOME/Applications/Nokcandu.app"
  echo "Installed ~/Applications/Nokcandu.app"
fi

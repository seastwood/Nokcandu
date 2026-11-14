#!/bin/bash
# Builds build/Nokcandu.app from this Swift package (needs Xcode or the Command Line Tools).
#   ./build-app.sh            build only
#   ./build-app.sh --install  also copy to ~/Applications/Nokcandu.app
#   ./build-app.sh --test     run unit tests first
set -euo pipefail
# Restricted build environments can opt out of SwiftPM manifest sandboxing only.
SWIFT_OPTIONS=()
if [ "${NOKCANDU_SWIFTPM_DISABLE_SANDBOX:-0}" = 1 ]; then SWIFT_OPTIONS+=(--disable-sandbox); fi
if [ -n "${NOKCANDU_SWIFTPM_SCRATCH_PATH:-}" ]; then SWIFT_OPTIONS+=(--scratch-path "$NOKCANDU_SWIFTPM_SCRATCH_PATH"); fi
if [ -n "${NOKCANDU_SWIFTPM_BUILD_SYSTEM:-}" ]; then SWIFT_OPTIONS+=(--build-system "$NOKCANDU_SWIFTPM_BUILD_SYSTEM"); fi
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

if [ "${1:-}" = --test ]; then swift test ${SWIFT_OPTIONS[@]+"${SWIFT_OPTIONS[@]}"}; shift || true; fi
# Development only: `touch .e2e` to also run the end-to-end install test (creates and removes a test app).
if [ -e .e2e-engine ]; then rm -f .e2e-engine; NOKCANDU_E2E=1 /usr/bin/perl -e "alarm 900; exec @ARGV" swift test --filter "$(cat .e2e-filter 2>/dev/null || echo EngineUpdateE2ETests)" 2>&1 | tee e2e-engine.log || true; /usr/bin/pkill -f "xctest.*E2ETests" || true; fi
if [ -e .e2e ]; then rm -f .e2e; NOKCANDU_E2E=1 /usr/bin/perl -e "alarm 900; exec @ARGV" swift test --filter E2ETests 2>&1 | tee e2e.log || true; /usr/bin/pkill -f "xctest.*E2ETests" || true; fi

# Resolve signing before spending time on compilation. Never silently discard a configured identity.
source scripts/select-signing-identity.sh
nokcandu_select_signing_identity

swift build ${SWIFT_OPTIONS[@]+"${SWIFT_OPTIONS[@]}"} -c release --product Nokcandu
swift build ${SWIFT_OPTIONS[@]+"${SWIFT_OPTIONS[@]}"} -c release --product nokcandu-screen-size
swift build ${SWIFT_OPTIONS[@]+"${SWIFT_OPTIONS[@]}"} -c release --product nokcandu-settings
BIN="$(swift build ${SWIFT_OPTIONS[@]+"${SWIFT_OPTIONS[@]}"} -c release --show-bin-path)"

APP="build/Nokcandu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Nokcandu" "$APP/Contents/MacOS/Nokcandu"
cp "$BIN/nokcandu-screen-size" "$APP/Contents/Resources/screen-size"
cp "$BIN/nokcandu-settings" "$APP/Contents/Resources/nokcandu-settings"
cp Resources/refresh-generals-launcher.py Resources/build-icu-adapter.py Resources/generals-launcher "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/Resources/generals-launcher" "$APP/Contents/Resources/screen-size"
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -O2 -Wall -Wextra -Werror -framework CoreFoundation Resources/launcher-entry/main.c -o "$APP/Contents/Resources/nokcandu-launcher"
./Resources/borderless/build.sh "$(pwd)/$APP/Contents/Resources"
./Resources/cabextract/build.sh "$(pwd)/$APP/Contents/Resources"
# Nokcandu's helper library loaded into Wine: raw mouse, hot corners, game names, sound that follows the Mac's
# devices and Bonjour from the Mac (the resizable window lives in Nokcandu's Wine Mac driver, Engine/winemac).
# Built for both x86_64 (today's Wine runs under Rosetta) and arm64 (a native Wine later) — nothing in it is
# specific to one architecture.
HELPER_BUILD="$( { cat Resources/rawmouse/*.[cmh] Sources/NokcanduPadEngine/padengine.c Sources/NokcanduPadEngine/include/padengine.h; printf '%s' 'macos11-universal-O2-v1'; } | shasum -a 256 | cut -d' ' -f1)"
printf '%s\n' "$HELPER_BUILD" > "$APP/Contents/Resources/helper-build.txt"
xcrun clang -arch x86_64 -arch arm64 -mmacosx-version-min=11.0 -dynamiclib -fobjc-arc -O2 -Wall \
  -framework AppKit -framework GameController -framework CoreGraphics -framework IOKit -framework OpenGL \
  -framework AudioToolbox -framework CoreAudio \
  -ISources/NokcanduPadEngine/include \
  -install_name @rpath/nokcandu-rawmouse.dylib "-DNOKCANDU_HELPER_BUILD=\"$HELPER_BUILD\"" \
  -o "$APP/Contents/Resources/nokcandu-rawmouse.dylib" Resources/rawmouse/rawmouse.m Resources/rawmouse/audiofollow.m Resources/rawmouse/bonjourbridge.m Resources/rawmouse/micguard.m Resources/rawmouse/socket-events.c Resources/rawmouse/helper-state.c Resources/rawmouse/commit-memory.c Sources/NokcanduPadEngine/padengine.c
# Nokcandu's Wine Mac drivers (resizable game windows), one per Wine version in Engine/winemac/SUPPORTED_WINE,
# built by Engine/winemac/build.sh into build/winemac-<version> (Wine 10.0's may also be in build/winemac).
# Bundled as Resources/winemac/<version>/; Nokcandu puts each into engines of that Wine version.
rm -rf "$APP/Contents/Resources/winemac"
for V in $(cat Engine/winemac/SUPPORTED_WINE); do
  D="build/winemac-$V"; [ -f "$D/x86_64-unix/winemac.so" ] || { [ "$V" = 10.0 ] && D=build/winemac; }
  if [ -f "$D/x86_64-unix/winemac.so" ]; then
    mkdir -p "$APP/Contents/Resources/winemac/$V"
    cp -R "$D/x86_64-unix" "$D/x86_64-windows" "$D/i386-windows" "$APP/Contents/Resources/winemac/$V/"
    echo "$V" > "$APP/Contents/Resources/winemac/$V/wine-version"
    [ -f "$D/server-requests" ] && cp "$D/server-requests" "$APP/Contents/Resources/winemac/$V/"
  elif [ "${NOKCANDU_REQUIRE_WINEMAC:-0}" = 1 ]; then
    echo "Nokcandu's Wine Mac driver for Wine $V isn't built (Engine/winemac/build.sh): a release needs it."; exit 1
  else
    echo "Note: no Wine Mac driver for Wine $V here (the resizable window won't be offered on those engines)."
  fi
done
# Exact-fingerprint USB Pro descriptor correction, built separately with SDL enabled.
HID_BUILD=build/controller-hid-11.0
[ -f "$HID_BUILD/winebus.so" ] || { echo "Build Engine/controller-hid/build.sh before packaging."; exit 1; }
python3 - "$HID_BUILD" <<'PYHID'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); m=json.loads((p/'manifest.json').read_text())
assert m['version']=='11.0' and m['sourceSHA256']==hashlib.sha256((p/'winebus.so').read_bytes()).hexdigest(), 'Controller module verification failed'
PYHID
mkdir -p "$APP/Contents/Resources/controller-hid/11.0"
cp "$HID_BUILD/winebus.so" "$HID_BUILD/manifest.json" "$HID_BUILD/wine-source.sha256" "$HID_BUILD/nokcandu-patch.sha256" "$APP/Contents/Resources/controller-hid/11.0/"
cp Engine/controller-hid/README.md Engine/controller-hid/build.sh Engine/controller-hid/sdl-runtime.sh Engine/controller-hid/000*.patch Engine/controller-hid/*.h "$APP/Contents/Resources/controller-hid/"
# The shared core the emulated controllers are built from (corresponding source for the module).
cp Sources/NokcanduPadEngine/virtualpad.c Sources/NokcanduPadEngine/include/virtualpad.h "$APP/Contents/Resources/controller-hid/"
cp "$HID_BUILD/COPYING.LIB" "$APP/Contents/Resources/controller-hid/"
# Native IPX is opt-in. Bundle only the engine version verified at runtime.
mkdir -p "$APP/Contents/Resources/native-ipx"
cp Resources/native-ipx/COPYING.LIB Resources/native-ipx/SOURCE.txt "$APP/Contents/Resources/native-ipx/"
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -O2 -Wall -Wextra -Werror Resources/native-ipx/access.c -o "$APP/Contents/Resources/native-ipx/native-ipx-access"
if [ -f build/wpcap-11.0/SHA256SUMS ]; then
  (cd build/wpcap-11.0 && shasum -a 256 -c SHA256SUMS)
  mkdir -p "$APP/Contents/Resources/native-ipx/11.0"
  cp -R build/wpcap-11.0/i386-windows build/wpcap-11.0/x86_64-windows build/wpcap-11.0/x86_64-unix "$APP/Contents/Resources/native-ipx/11.0/"
  cp build/wpcap-11.0/adapter-info.exe "$APP/Contents/Resources/native-ipx/11.0/"
  cp build/wpcap-11.0/wine-version build/wpcap-11.0/wine-source.sha256 build/wpcap-11.0/nokcandu-patch.sha256 "$APP/Contents/Resources/native-ipx/11.0/"
  cp Engine/wpcap/README.md Engine/wpcap/native-capture-11.0.patch Engine/wpcap/build.sh "$APP/Contents/Resources/native-ipx/"
elif [ "${NOKCANDU_REQUIRE_NATIVE_IPX:-0}" = 1 ]; then
  echo 'Native IPX module is missing. Build Engine/wpcap/build.sh for Wine 11 first.'; exit 1
else
  echo 'Note: native IPX will be unavailable without its Wine 11 module.'
fi
# Developer ID builds need hardened runtime and a secure timestamp for notarization.
HARDEN=()
if [ "${NOKCANDU_HARDENED:-0}" = 1 ]; then HARDEN=(--options runtime --timestamp); fi
[ "$SIGN_ID" = "-" ] && echo "Signing: ad-hoc (macOS will re-ask for permissions after each build)" || echo "Signing: $SIGN_ID"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} ${SIGN_KC[@]+"${SIGN_KC[@]}"} --sign "$SIGN_ID" "$APP/Contents/Resources/nokcandu-rawmouse.dylib"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} ${SIGN_KC[@]+"${SIGN_KC[@]}"} --sign "$SIGN_ID" "$APP/Contents/Resources/controller-hid/11.0/winebus.so"
python3 - "$APP/Contents/Resources/controller-hid/11.0" <<'PYHIDSIGNED'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); m=json.loads((p/'manifest.json').read_text())
m['sourceSHA256']=hashlib.sha256((p/'winebus.so').read_bytes()).hexdigest()
(p/'manifest.json').write_text(json.dumps(m)+'\n')
PYHIDSIGNED
for SO in "$APP"/Contents/Resources/winemac/*/x86_64-unix/winemac.so; do
  [ -f "$SO" ] && codesign --force ${HARDEN[@]+"${HARDEN[@]}"} ${SIGN_KC[@]+"${SIGN_KC[@]}"} --sign "$SIGN_ID" "$SO"
done

if [ -f "$APP/Contents/Resources/native-ipx/11.0/x86_64-unix/wpcap.so" ]; then
  codesign --force ${HARDEN[@]+"${HARDEN[@]}"} ${SIGN_KC[@]+"${SIGN_KC[@]}"} --sign "$SIGN_ID" "$APP/Contents/Resources/native-ipx/11.0/x86_64-unix/wpcap.so"
  (cd "$APP/Contents/Resources/native-ipx/11.0" && shasum -a 256 i386-windows/wpcap.dll x86_64-windows/wpcap.dll x86_64-unix/wpcap.so adapter-info.exe > SHA256SUMS)
fi

codesign --force ${HARDEN[@]+"${HARDEN[@]}"} ${SIGN_KC[@]+"${SIGN_KC[@]}"} --sign "$SIGN_ID" "$APP/Contents/Resources/nokcandu-launcher"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} ${SIGN_KC[@]+"${SIGN_KC[@]}"} --sign "$SIGN_ID" "$APP/Contents/Resources/cabextract"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} ${SIGN_KC[@]+"${SIGN_KC[@]}"} --sign "$SIGN_ID" "$APP/Contents/Resources/native-ipx/native-ipx-access"

# App icon (original artwork in Resources/AppIcon.png)
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z $d $d Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "warning: icon not built"

VERSION="$(tr -d '[:space:]' < VERSION)"
# What's New: this version's release notes, shown once after an update.
[ -f "release-notes/v$VERSION.md" ] && cp "release-notes/v$VERSION.md" "$APP/Contents/Resources/WhatsNew.md"
# Every version's notes too: someone updating across several versions is shown each one they missed.
mkdir -p "$APP/Contents/Resources/ReleaseNotes"
cp release-notes/v*.md "$APP/Contents/Resources/ReleaseNotes/"
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
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>LSSupportsGameMode</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Battle.net sign-in return (forwarded to Battle.net in Wine)</string>
    <key>CFBundleURLSchemes</key><array><string>battlenet</string><string>blizzard</string></array>
  </dict><dict>
    <key>CFBundleURLName</key><string>Nokcandu game profiles</string>
    <key>CFBundleURLSchemes</key><array><string>nokcandu</string></array>
  </dict></array>
  <key>NSMotionUsageDescription</key><string>Use compatible headphone head motion as an optional controller input.</string>
  <key>NSMicrophoneUsageDescription</key><string>Games started from Nokcandu, and streams you choose to send it to, can use your microphone for voice chat.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Streams finds and connects to computers on your network that stream games to this Mac.</string>
  <key>NSBonjourServices</key><array><string>_nvstream._tcp</string></array>
  <key>NSDocumentsFolderUsageDescription</key><string>Nokcandu reads and adjusts some games' settings in your Documents folder.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Nokcandu installs games from installers and disc images you choose in Downloads.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Nokcandu keeps games and game files on drives you choose, like an external SSD.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Nokcandu can install games from a network drive you choose.</string>
</dict>
</plist>
PLIST

# Signed with the identity chosen above (not notarized).
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} ${SIGN_KC[@]+"${SIGN_KC[@]}"} --sign "$SIGN_ID" "$APP/Contents/Resources/screen-size"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} ${SIGN_KC[@]+"${SIGN_KC[@]}"} --sign "$SIGN_ID" "$APP/Contents/Resources/nokcandu-settings"
# Virtual controllers on the Mac (CoreHID) need Apple's com.apple.developer.hid.virtual.device entitlement, which only
# works with an Apple-issued provisioning profile that grants it. Without one macOS kills an app that claims it, so
# it's added only when NOKCANDU_PROVISIONING_PROFILE points at such a profile (Developer ID signing). See
# docs/controller-capabilities.md.
APP_ENTITLEMENTS=()
if [ -n "${NOKCANDU_PROVISIONING_PROFILE:-}" ]; then
  [ -f "$NOKCANDU_PROVISIONING_PROFILE" ] || { echo "NOKCANDU_PROVISIONING_PROFILE doesn't exist."; exit 1; }
  security cms -D -i "$NOKCANDU_PROVISIONING_PROFILE" 2>/dev/null | grep -q 'com.apple.developer.hid.virtual.device' \
    || { echo "The provisioning profile doesn't grant com.apple.developer.hid.virtual.device."; exit 1; }
  cp "$NOKCANDU_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  ENT="$(mktemp -t nokcandu-entitlements).plist"
  cat > "$ENT" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.developer.hid.virtual.device</key><true/></dict></plist>
ENTITLEMENTS
  APP_ENTITLEMENTS=(--entitlements "$ENT")
  echo "Virtual controllers on the Mac: entitlement granted by the provisioning profile"
fi
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} ${SIGN_KC[@]+"${SIGN_KC[@]}"} ${APP_ENTITLEMENTS[@]+"${APP_ENTITLEMENTS[@]}"} --sign "$SIGN_ID" "$APP"
echo "Built $(pwd)/$APP"

if [ "${1:-}" = --install ]; then
  bash scripts/check-signing-continuity.sh "$HOME/Applications/Nokcandu.app" "$APP"
  mkdir -p "$HOME/Applications"
  "$APP/Contents/Resources/nokcandu-settings" --install-app "$(pwd)/$APP" "$HOME/Applications/Nokcandu.app"
  echo "Installed ~/Applications/Nokcandu.app"
fi

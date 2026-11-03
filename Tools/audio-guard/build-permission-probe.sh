#!/bin/bash
set -euo pipefail
# Optional manual test. Never overwrites an app or changes existing privacy consent.
MODE="${1:?Choose off or on}"
APP="${2:?Choose a new absolute .app path}"
case "$MODE" in off|on) ;; *) echo 'Choose off or on'; exit 2;; esac
case "$APP" in /*.app) ;; *) echo 'Choose an absolute .app path'; exit 2;; esac
[ ! -e "$APP" ] && [ ! -L "$APP" ] || { echo 'Destination already exists; choose a new path.'; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IDENTIFIER="local.nokcandu.audio-proof.$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AudioCheck</string>
<key>CFBundleIdentifier</key><string>$IDENTIFIER</string>
<key>CFBundleName</key><string>Nokcandu Audio $MODE Check</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ "$MODE" = on ]; then
 /usr/bin/plutil -insert NSMicrophoneUsageDescription -string 'Test normal microphone permission handling. This diagnostic does not record audio.' "$APP/Contents/Info.plist"
fi
/usr/bin/plutil -insert LSEnvironment -xml '<dict/>' "$APP/Contents/Info.plist"
/usr/bin/plutil -insert LSEnvironment.DYLD_INSERT_LIBRARIES -string "$APP/Contents/Frameworks/guard.dylib" "$APP/Contents/Info.plist"
xcrun clang -arch x86_64 -dynamiclib -O2 -framework CoreAudio "$ROOT/Resources/rawmouse/micguard.m" -o "$APP/Contents/Frameworks/guard.dylib"
codesign --force --sign - "$APP/Contents/Frameworks/guard.dylib"
xcrun clang -arch x86_64 -fobjc-arc -O2 -framework AppKit -framework AudioToolbox -framework CoreAudio \
 "$ROOT/Tools/audio-guard/permission-probe.m" -o "$APP/Contents/MacOS/AudioCheck"
codesign --force --sign - "$APP"
echo "Built $APP ($MODE; fresh privacy identity; no audio recording)."

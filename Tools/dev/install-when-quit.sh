#!/bin/bash
# Development helper: installs build/Nokcandu.app as soon as Nokcandu quits, then opens it.
cd "$(dirname "$0")/../.."
while pgrep -qx Nokcandu; do sleep 3; done
sleep 1
build/Nokcandu.app/Contents/Resources/nokcandu-settings --install-app "$(pwd)/build/Nokcandu.app" "$HOME/Applications/Nokcandu.app" > install-when-quit.log 2>&1 && open "$HOME/Applications/Nokcandu.app"
launchctl remove nokcandu.installwait 2>/dev/null

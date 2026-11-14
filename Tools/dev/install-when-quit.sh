#!/bin/bash
# Development helper: installs build/Nokcandu.app as soon as Nokcandu quits, then opens it.
# If Nokcandu is opened again before the install could start (it refuses while Nokcandu runs), it waits for the
# next quit instead of giving up: a missed install once left an older build running unnoticed.
cd "$(dirname "$0")/../.."
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  while pgrep -qx Nokcandu; do sleep 3; done
  sleep 1
  if build/Nokcandu.app/Contents/Resources/nokcandu-settings --install-app "$(pwd)/build/Nokcandu.app" "$HOME/Applications/Nokcandu.app" > install-when-quit.log 2>&1; then
    open "$HOME/Applications/Nokcandu.app"
    break
  fi
  sleep 5
done
launchctl remove nokcandu.installwait 2>/dev/null

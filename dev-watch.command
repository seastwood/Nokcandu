#!/bin/bash
# Development helper: rebuilds Nokcandu whenever a ".rebuild" file appears in this folder.
# Close this Terminal window to stop it.
cd "$(dirname "$0")"
echo "Watching for rebuild requests in $(pwd)…"
touch .rebuild
while true; do
  if [ -e .rebuild ]; then
    rm -f .rebuild
    { echo "== $(date)"; ./build-app.sh --test --install; echo "EXIT=$?"; } 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tee build.log
  fi
  if [ -e .relaunch ]; then
    rm -f .relaunch
    pkill -x Nokcandu; sleep 1; open "$HOME/Applications/Nokcandu.app"
  fi
  sleep 2
done

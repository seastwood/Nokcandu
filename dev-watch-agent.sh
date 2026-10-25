#!/bin/bash
# Development helper run by launchd at login (io.github.seastwood.nokcandu.devwatch): same as dev-watch.command,
# without a Terminal window. Output: build.log (each build), watch-agent.log (the watcher itself).
cd "$(dirname "$0")"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
LOCK=".watch.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  OLD=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [[ "$OLD" =~ ^[0-9]+$ ]] && kill -0 "$OLD" 2>/dev/null; then echo "$(date) another watcher ($OLD) is running"; exit 0; fi
  rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" || exit 1
fi
echo $$ > "$LOCK/pid"
trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null' EXIT
# Let a Terminal watcher (dev-watch.command) finish first so two builds never run at once.
while /usr/bin/pgrep -qf "dev-watch.command"; do sleep 5; done
echo "$(date) watching $(pwd)"
while true; do
  if [ -e .rebuild ]; then
    rm -f .rebuild
    { echo "== $(date)"; ./build-app.sh --test --install; echo "EXIT=$?"; } 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > build.log
  fi
  if [ -e .relaunch ]; then
    rm -f .relaunch
    pkill -x Nokcandu; sleep 1; open "$HOME/Applications/Nokcandu.app"
  fi
  sleep 2
done

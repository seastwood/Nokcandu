#!/bin/bash
# Double-click to (re)build Nokcandu. Output also goes to build.log next to this file.
cd "$(dirname "$0")"
{ echo "== $(date)"; ./build-app.sh --test --install; echo "EXIT=$?"; } 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tee build.log

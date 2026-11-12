#!/bin/bash
# Verify the same toolchain used for the installed controller-overhaul build.
set -euo pipefail
actual="$(xcodebuild -version)"
[ "$actual" = $'Xcode 27.2\nBuild version 27B52' ] || {
  echo 'Expected Xcode 27.2 (27B52); refusing a different/default toolchain.' >&2
  printf '%s\n' "$actual" >&2
  exit 1
}
printf '%s\n' "$actual"
swift --version
xcrun --sdk macosx --show-sdk-version

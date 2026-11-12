#!/bin/bash
# Guard local installations against accidentally replacing certificate-signed code
# with a different identity. Uses codesign's own requirement evaluation.
set -euo pipefail
CURRENT="${1:?Current app required}"
INCOMING="${2:?Incoming app required}"
[ -d "$CURRENT" ] || exit 0
if [ "${NOKCANDU_ALLOW_SIGNING_CHANGE:-0}" = 1 ]; then
  echo 'Explicit signing transition allowed; macOS permissions may require renewed authorization.' >&2
  exit 0
fi
DETAILS="$(codesign --display --verbose=2 "$CURRENT" 2>&1)" || { echo 'Could not inspect installed signing identity.' >&2; exit 1; }
# Ad-hoc already has a version-specific identity; permit the one-time move to stable signing.
if [[ "$DETAILS" == *'Signature=adhoc'* ]]; then exit 0; fi
REQUIREMENT="$(codesign --display -r- "$CURRENT" 2>&1 | sed -n 's/^designated => //p')"
if [ -z "$REQUIREMENT" ] || ! codesign --verify --strict -R "=$REQUIREMENT" "$INCOMING" >/dev/null 2>&1; then
  echo 'Refusing to install a build that changes Nokcandu’s existing signing identity. Rebuild with the same signing identity to preserve permissions. For an intentional one-time transition, set NOKCANDU_ALLOW_SIGNING_CHANGE=1.' >&2
  exit 1
fi

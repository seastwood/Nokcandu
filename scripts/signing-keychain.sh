#!/bin/bash
# Puts the "Nokcandu Signing" identity in its own keychain (~/Library/Keychains/nokcandu-signing.keychain-db)
# whose password lives next to it in Application Support (only readable by you). build-app.sh unlocks it
# itself, and codesign is pre-authorised for the key, so builds never ask for your login keychain password.
# Usage: scripts/signing-keychain.sh <identity.p12.base64> <password file>
set -euo pipefail
KC="$HOME/Library/Keychains/nokcandu-signing.keychain-db"
PWF="$HOME/Library/Application Support/Nokcandu/signing-keychain.password"
P12B64="$1"; P12PASS="$(cat "$2")"
mkdir -p "$(dirname "$PWF")"
if [ ! -f "$KC" ]; then
  ( umask 077; openssl rand -hex 24 > "$PWF" )
  security create-keychain -p "$(cat "$PWF")" "$KC"
fi
KCPASS="$(cat "$PWF")"
security unlock-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"                       # no auto-lock
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
base64 -D -i "$P12B64" -o "$D/id.p12"
security import "$D/id.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign 2>&1 | grep -v "already exists" || true
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null
# Keep it in the search list (after the existing keychains).
LIST=(); while IFS= read -r k; do k="${k//\"/}"; k="${k#"${k%%[![:space:]]*}"}"; [ -n "$k" ] && [ "$k" != "$KC" ] && LIST+=("$k"); done < <(security list-keychains -d user)
security list-keychains -d user -s "${LIST[@]}" "$KC"
security find-identity -p codesigning "$KC"

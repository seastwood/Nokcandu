#!/bin/bash
# Sourced by build-app.sh. Never creates identities or modifies trust/ACL settings.
# A configured but inaccessible keychain must not silently downgrade a build to ad-hoc.
nokcandu_select_signing_identity() {
  SIGN_ID="${NOKCANDU_SIGN_IDENTITY:-}"
  SIGN_KC=()
  if [ -n "$SIGN_ID" ]; then return 0; fi
  local signing_kc="${NOKCANDU_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/nokcandu-signing.keychain-db}"
  local signing_pw="${NOKCANDU_SIGNING_PASSWORD_FILE:-$HOME/Library/Application Support/Nokcandu/signing-keychain.password}"
  if [ -e "$signing_kc" ] || [ -e "$signing_pw" ]; then
    if [ ! -r "$signing_kc" ] || [ ! -r "$signing_pw" ]; then
      echo 'Nokcandu signing is configured but its keychain/password file is unavailable. Refusing an ad-hoc fallback; run the build with access to the existing signing keychain.' >&2
      return 1
    fi
    if ! security unlock-keychain -p "$(cat "$signing_pw")" "$signing_kc" >/dev/null 2>&1; then
      echo 'Could not unlock the existing Nokcandu signing keychain. Refusing an ad-hoc fallback; no signing identity or permissions were reset.' >&2
      return 1
    fi
    if ! SIGN_ID="$(security find-identity -p codesigning "$signing_kc" 2>/dev/null | awk '/"Nokcandu Signing"/ { print $2; exit }')"; then SIGN_ID=""; fi
    if [ -z "$SIGN_ID" ]; then
      echo 'The configured Nokcandu signing keychain exposes no Nokcandu Signing identity. Refusing an ad-hoc fallback.' >&2
      return 1
    fi
    SIGN_KC=(--keychain "$signing_kc")
    return 0
  fi
  SIGN_ID="$(security find-identity -p codesigning 2>/dev/null | awk '/"Nokcandu Signing"/ { print $2; exit }')"
  SIGN_ID="${SIGN_ID:--}"
}

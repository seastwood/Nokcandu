#!/bin/bash
# Creates a private code-signing identity ("Nokcandu Signing") in your login keychain.
# Why: macOS remembers permissions (Input Monitoring, removable drives, Documents…) per app *signature*.
# Ad-hoc builds get a new signature every build, so macOS asks again after every update. Signing every
# build with the same identity keeps the permissions. Run once; build-app.sh picks it up automatically.
# For GitHub releases, add the printed .p12 (base64) and password as repository secrets
# NOKCANDU_SIGNING_P12 and NOKCANDU_SIGNING_PASSWORD.
set -euo pipefail
NAME="${1:-Nokcandu Signing}"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then echo "Already exists: $NAME"; exit 0; fi
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
cat > "$D/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -keyout "$D/key.pem" -out "$D/cert.pem" -config "$D/cfg" 2>/dev/null
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -inkey "$D/key.pem" -in "$D/cert.pem" -name "$NAME" -out "$D/id.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -name "$NAME" -out "$D/id.p12" -passout "pass:$PASS"
security import "$D/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
OUT="$HOME/Documents/Nokcandu Signing (keep private).p12.base64"
( umask 077; base64 -i "$D/id.p12" > "$OUT" )
( umask 077; echo "$PASS" > "$OUT.password" )
echo "Created \"$NAME\". For GitHub releases: secret NOKCANDU_SIGNING_P12 = contents of $OUT, NOKCANDU_SIGNING_PASSWORD = contents of $OUT.password (keep both private)."

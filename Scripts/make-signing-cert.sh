#!/bin/bash
# Creates one self-signed code signing identity so every build carries the same
# signature. Without this, an ad-hoc signature changes on every build, macOS
# treats each build as a different application, and the Keychain prompt for
# Claude Code's credentials returns every single time.
#
# Interactive: macOS asks for your login keychain password.
# Run once. Then: export CODESIGN_IDENTITY="Claudence Dev"
set -euo pipefail

NAME="${1:-Claudence Dev}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "identity '$NAME' already exists"
    exit 0
fi

cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/openssl.cnf"

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout pass:

security import "$TMP/identity.p12" -k ~/Library/Keychains/login.keychain-db \
    -T /usr/bin/codesign -P ""

echo
echo "created '$NAME'. now run:"
echo "  export CODESIGN_IDENTITY=\"$NAME\""

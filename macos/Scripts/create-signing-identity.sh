#!/usr/bin/env bash
# Create a stable, self-signed code-signing identity so macOS permissions survive rebuilds.
#
# macOS keys Accessibility / Screen Recording / Input Monitoring grants to the app's *code
# signature*. The default ad-hoc signature changes on every rebuild, so those grants keep
# silently ceasing to apply — the settings switch stays on, but it belongs to the previous
# binary. A self-signed certificate gives a constant identity that rebuilds share.
#
# One-time setup. Usage: Scripts/create-signing-identity.sh [name]
set -euo pipefail

NAME="${1:-GhostHand Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
P12_PASS="ghosthand-local"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Identity '$NAME' already exists:"
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Generating self-signed code-signing certificate '$NAME'"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$NAME/O=GhostHand/C=US" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# macOS's Security framework only understands legacy PKCS#12 (3DES / SHA-1) encryption, so
# OpenSSL 3's default AES-based output cannot be imported without these flags.
echo "==> Exporting a macOS-compatible PKCS#12"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout "pass:$P12_PASS" -name "$NAME" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

echo "==> Importing into the login keychain"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security

echo "==> Trusting it for code signing (user domain)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo ""
echo "==> Ready:"
security find-identity -v -p codesigning | grep "$NAME"
echo ""
echo "Rebuild with Scripts/make-app-bundle.sh -c release. Grant permissions once more;"
echo "from then on they survive rebuilds."

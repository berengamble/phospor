#!/usr/bin/env bash
# Creates a self-signed code signing certificate for Phospor dev builds.
# This gives TCC a stable signing identity so screen recording / camera /
# microphone permissions persist across rebuilds.
#
# Run once. The certificate lives in your login keychain for 10 years.

set -euo pipefail

CERT_NAME="Phospor Dev"

# Already exists?
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✓ Certificate '$CERT_NAME' already exists in your keychain"
    exit 0
fi

echo "▶ Creating self-signed code signing certificate '$CERT_NAME'..."
echo "  This fixes TCC permission loss across rebuilds."
echo ""

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Generate self-signed code signing cert via openssl.
cat > "$TMPDIR/cert.conf" << 'CONF'
[req]
distinguished_name = dn
x509_extensions = codesign
prompt = no

[dn]
CN = Phospor Dev

[codesign]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMPDIR/key.pem" \
    -out "$TMPDIR/cert.pem" \
    -days 3650 \
    -config "$TMPDIR/cert.conf" \
    -sha256 2>/dev/null

# Bundle into a .p12 for keychain import. Use legacy PKCS12 options so
# macOS Security framework can read it (OpenSSL 3.x defaults are
# incompatible).
openssl pkcs12 -export \
    -out "$TMPDIR/cert.p12" \
    -inkey "$TMPDIR/key.pem" \
    -in "$TMPDIR/cert.pem" \
    -passout pass:phospor \
    -certpbe PBE-SHA1-3DES \
    -keypbe PBE-SHA1-3DES \
    -macalg sha1 2>/dev/null

echo "▶ Importing into login keychain..."
security import "$TMPDIR/cert.p12" \
    -k ~/Library/Keychains/login.keychain-db \
    -P "phospor" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

# Trust the certificate for code signing so codesign accepts it.
echo "▶ Trusting certificate for code signing..."
echo "  You may be prompted for your macOS login password."
security find-certificate -c "$CERT_NAME" -p \
    ~/Library/Keychains/login.keychain-db > "$TMPDIR/trust.pem"
security add-trusted-cert -p codeSign "$TMPDIR/trust.pem"

# Allow codesign to use the key without a prompt on each build.
security set-key-partition-list -S apple-tool:,apple: -s \
    -k "" ~/Library/Keychains/login.keychain-db 2>/dev/null || {
    echo ""
    echo "⚠  Could not set partition list automatically."
    echo "   If codesign prompts for keychain access on each build,"
    echo "   click 'Always Allow' once and it won't ask again."
}

echo ""
# Verify
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✓ Certificate '$CERT_NAME' created successfully"
    echo "  TCC permissions will now persist across rebuilds."
    echo ""
    echo "  IMPORTANT: Go to System Settings → Privacy & Security → Screen Recording,"
    echo "  remove the old Phospor entry, rebuild, and re-approve once. After that"
    echo "  it sticks permanently."
else
    echo "✗ Automatic certificate creation failed."
    echo ""
    echo "  Create manually instead:"
    echo "  1. Open Keychain Access"
    echo "  2. Menu → Certificate Assistant → Create a Certificate..."
    echo "  3. Name: $CERT_NAME"
    echo "  4. Identity Type: Self Signed Root"
    echo "  5. Certificate Type: Code Signing"
    echo "  6. Click Create"
    exit 1
fi

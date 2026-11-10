#!/bin/sh
# One-time personal-use identity. No Apple account, network or trust changes.
set -eu
umask 077
SIGNING_DIR="${LEDGER_SIGNING_DIR:-$HOME/Library/Application Support/LedgerSigning}"
KEYCHAIN="$SIGNING_DIR/identity.keychain-db"
if [ -f "$SIGNING_DIR/ready" ]; then
    echo "Ledger signing is already configured. Its existing identity is retained."
    exit 0
fi
# Never regenerate a lost/partial identity silently: that would break permissions.
if [ -e "$SIGNING_DIR" ]; then
    echo "Signing setup is incomplete at $SIGNING_DIR. Recover the existing identity before retrying; do not replace it automatically." >&2
    exit 1
fi
mkdir -p "$(dirname "$SIGNING_DIR")"
mkdir -m 700 "$SIGNING_DIR"
WORK=$(mktemp -d "$SIGNING_DIR/setup.XXXXXX")
cleanup() {
    rm -rf "$WORK"
    security lock-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
}
trap cleanup EXIT
openssl rand -hex 32 > "$SIGNING_DIR/keychain-password"
PASSWORD=$(cat "$SIGNING_DIR/keychain-password")
cat > "$WORK/certificate.conf" <<'CONF'
[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = Ledger Personal Local Signing
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONF
openssl req -new -newkey rsa:3072 -nodes -x509 -days 3650 \
    -config "$WORK/certificate.conf" -keyout "$WORK/key.pem" \
    -out "$WORK/certificate.pem" >/dev/null 2>&1
openssl x509 -in "$WORK/certificate.pem" -outform DER -out "$SIGNING_DIR/certificate.cer"
openssl x509 -in "$WORK/certificate.pem" -noout -fingerprint -sha1 \
    | sed 's/.*=//;s/://g' > "$SIGNING_DIR/identity.sha1"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/certificate.pem" \
    -out "$WORK/identity.p12" -passout "file:$SIGNING_DIR/keychain-password" \
    -name 'Ledger Personal Local Signing'
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -x -T /usr/bin/codesign >/dev/null
# Only signing tools may use this key without a prompt, in this dedicated keychain.
security set-key-partition-list -S apple-tool:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
chmod 600 "$KEYCHAIN" "$SIGNING_DIR/keychain-password" "$SIGNING_DIR/certificate.cer" "$SIGNING_DIR/identity.sha1"
touch "$SIGNING_DIR/ready"
echo "Ledger's persistent personal signing identity is ready. Keep $SIGNING_DIR; it is separate from build caches and Git."

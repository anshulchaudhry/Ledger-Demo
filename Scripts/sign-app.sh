#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
    echo "Usage: sh Scripts/sign-app.sh APP BUNDLE_ID" >&2
    exit 1
fi
APP=$1
BUNDLE_ID=$2
case "$BUNDLE_ID" in
    local.ledger.preview|local.ledger.demo|local.ledger.signing-check) ;;
    *) echo "Unexpected Ledger bundle identity." >&2; exit 1 ;;
esac
SIGNING_DIR="${LEDGER_SIGNING_DIR:-$HOME/Library/Application Support/LedgerSigning}"
KEYCHAIN="$SIGNING_DIR/identity.keychain-db"
for FILE in ready identity.keychain-db keychain-password certificate.cer identity.sha1; do
    if [ ! -f "$SIGNING_DIR/$FILE" ]; then
        echo "Persistent signing is unavailable. Run sh Scripts/setup-signing.sh once, or recover the existing identity. No ad-hoc fallback is allowed." >&2
        exit 1
    fi
done
HASH=$(cat "$SIGNING_DIR/identity.sha1")
case "$HASH" in ''|*[!0-9A-Fa-f]*) echo "Invalid signing fingerprint." >&2; exit 1 ;; esac
[ "${#HASH}" -eq 40 ] || { echo "Invalid signing fingerprint length." >&2; exit 1; }
CERT_HASH=$(openssl x509 -inform DER -in "$SIGNING_DIR/certificate.cer" -noout -fingerprint -sha1 | sed 's/.*=//;s/://g')
[ "$HASH" = "$CERT_HASH" ] || { echo "Signing certificate changed. The app was not replaced." >&2; exit 1; }
openssl x509 -inform DER -in "$SIGNING_DIR/certificate.cer" -checkend 0 -noout >/dev/null || {
    echo "The signing certificate has expired. Plan an explicit signing migration; no replacement identity was generated." >&2
    exit 1
}
# Serialize access without changing any other keychain or its access controls.
mkdir "$SIGNING_DIR/signing.lock" 2>/dev/null || { echo "Another signing operation is active; retry when it finishes." >&2; exit 1; }
cleanup() {
    security lock-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    rmdir "$SIGNING_DIR/signing.lock"
}
trap cleanup EXIT
PASSWORD=$(cat "$SIGNING_DIR/keychain-password")
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
REQUIREMENT="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$HASH\""
codesign --force --sign "$HASH" --keychain "$KEYCHAIN" --timestamp=none \
    --identifier "$BUNDLE_ID" --requirements "=designated => $REQUIREMENT" "$APP"
codesign --verify --strict --verbose=2 --test-requirement "=$REQUIREMENT" "$APP"

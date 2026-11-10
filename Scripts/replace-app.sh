#!/bin/sh
# Verify before replacing, and preserve the previous bundle on a failed update.
set -eu
if [ "$#" -ne 3 ]; then
    echo "Usage: sh Scripts/replace-app.sh SOURCE DESTINATION BUNDLE_ID" >&2
    exit 1
fi
SOURCE=$1
DESTINATION=$2
BUNDLE_ID=$3
codesign --verify --strict "$SOURCE"
SOURCE_DETAILS=$(codesign -d -r- "$SOURCE" 2>&1)
SOURCE_REQUIREMENT=$(printf '%s\n' "$SOURCE_DETAILS" | sed -n 's/^#\{0,1\} *designated => //p')
case "$SOURCE_REQUIREMENT" in
    "identifier \"$BUNDLE_ID\" and certificate leaf = H\""*) ;;
    *) echo "Update rejected: a persistent certificate signature is required." >&2; exit 1 ;;
esac
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE/Contents/Info.plist")" = "$BUNDLE_ID" ] || {
    echo "Source app has the wrong bundle identity." >&2; exit 1
}
if [ -e "$DESTINATION" ]; then
    [ ! -L "$DESTINATION" ] || { echo "Refusing to replace an app symlink." >&2; exit 1; }
    [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DESTINATION/Contents/Info.plist")" = "$BUNDLE_ID" ] || {
        echo "Destination contains a different app; nothing was replaced." >&2; exit 1
    }
    DETAILS=$(codesign -d -r- "$DESTINATION" 2>&1)
    PREVIOUS_REQUIREMENT=$(printf '%s\n' "$DETAILS" | sed -n 's/^#\{0,1\} *designated => //p')
    [ -n "$PREVIOUS_REQUIREMENT" ] || { echo "Cannot verify the previous app identity; nothing was replaced." >&2; exit 1; }
    case "$PREVIOUS_REQUIREMENT" in
        cdhash\ H*)
            echo "Replacing the old development signature with a persistent personal identity."
            if [ "$BUNDLE_ID" = local.ledger.preview ]; then
                echo "Ledger's Full Disk Access must be approved once for the new identity."
            fi
            ;;
        *) codesign --verify --strict --test-requirement "=$PREVIOUS_REQUIREMENT" "$SOURCE" || {
            echo "Update rejected: signing identity changed. The previous app is intact." >&2; exit 1
        } ;;
    esac
fi
PARENT=$(dirname "$DESTINATION")
mkdir -p "$PARENT"
STAGING=$(mktemp -d "$PARENT/.ledger-install.XXXXXX")
COMMITTED=false
REPLACED=false
cleanup() {
    if [ "$COMMITTED" = false ]; then
        if [ "$REPLACED" = true ]; then rm -rf "$DESTINATION"; fi
        if [ -d "$STAGING/Previous.app" ]; then
            mv "$STAGING/Previous.app" "$DESTINATION"
        fi
    fi
    rm -rf "$STAGING"
}
trap cleanup EXIT
ditto --norsrc --noextattr "$SOURCE" "$STAGING/New.app"
codesign --verify --strict "$STAGING/New.app"
if [ -e "$DESTINATION" ]; then mv "$DESTINATION" "$STAGING/Previous.app"; fi
mv "$STAGING/New.app" "$DESTINATION"
REPLACED=true
chflags nohidden "$DESTINATION"
codesign --verify --strict "$DESTINATION"
COMMITTED=true

#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

if [ "$#" -ne 2 ]; then
    echo "Usage: sh Scripts/package-demo-release.sh 'Developer ID Application: Name (TEAMID)' NOTARY_PROFILE" >&2
    exit 1
fi
IDENTITY=$1
PROFILE=$2
case "$IDENTITY" in
    'Developer ID Application: '*) ;;
    *) echo "An Apple Developer ID Application identity is required." >&2; exit 1 ;;
esac
if ! security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""; then
    echo "The requested Developer ID Application identity is unavailable." >&2
    exit 1
fi

sh run-app.sh --demo --release --build-only
STAGING=$(mktemp -d "$PWD/.build/demo-dist.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Ledger Demo.app"
ditto --norsrc --noextattr LedgerDemo.app "$APP"
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" | grep -Fxq local.ledger.demo
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCH=$(lipo -archs "$APP/Contents/MacOS/Ledger")
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/notarization.zip"
xcrun notarytool submit "$STAGING/notarization.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute "$APP"

mkdir -p .build/dist
OUTPUT="$PWD/.build/dist/Ledger-Demo-$VERSION-macOS-$ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/release.zip"
mv "$STAGING/release.zip" "$OUTPUT"
shasum -a 256 "$OUTPUT"

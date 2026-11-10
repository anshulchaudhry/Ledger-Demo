#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
MASTER="$PWD/Resources/AppIcon/ledger-wallet.png"
ICONSET="$PWD/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
# Standard macOS icon sizes, including Retina representations. Preserve alpha.
for SIZE in 16 32 128 256 512; do
    RETINA=$((SIZE * 2))
    sips -z "$SIZE" "$SIZE" "$MASTER" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z "$RETINA" "$RETINA" "$MASTER" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil --convert icns "$ICONSET" --output "$PWD/.build/AppIcon.icns"
# Compile the same artwork into an asset catalog for current macOS icon lookup.
CATALOG="$PWD/.build/IconAssets.xcassets"
APPICON="$CATALOG/AppIcon.appiconset"
mkdir -p "$APPICON" "$PWD/.build/IconAssets"
cp "$ICONSET/"*.png "$APPICON/"
cat > "$CATALOG/Contents.json" <<'JSON'
{"info":{"author":"xcode","version":1}}
JSON
cat > "$APPICON/Contents.json" <<'JSON'
{"images":[
{"filename":"icon_16x16.png","idiom":"mac","size":"16x16","scale":"1x"},
{"filename":"icon_16x16@2x.png","idiom":"mac","size":"16x16","scale":"2x"},
{"filename":"icon_32x32.png","idiom":"mac","size":"32x32","scale":"1x"},
{"filename":"icon_32x32@2x.png","idiom":"mac","size":"32x32","scale":"2x"},
{"filename":"icon_128x128.png","idiom":"mac","size":"128x128","scale":"1x"},
{"filename":"icon_128x128@2x.png","idiom":"mac","size":"128x128","scale":"2x"},
{"filename":"icon_256x256.png","idiom":"mac","size":"256x256","scale":"1x"},
{"filename":"icon_256x256@2x.png","idiom":"mac","size":"256x256","scale":"2x"},
{"filename":"icon_512x512.png","idiom":"mac","size":"512x512","scale":"1x"},
{"filename":"icon_512x512@2x.png","idiom":"mac","size":"512x512","scale":"2x"}
],"info":{"author":"xcode","version":1}}
JSON
xcrun actool "$CATALOG" --compile "$PWD/.build/IconAssets" --app-icon AppIcon \
    --platform macosx --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$PWD/.build/IconInfo.plist" --output-format human-readable-text

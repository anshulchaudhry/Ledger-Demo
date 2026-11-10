#!/bin/sh
set -eu
cd "$(dirname "$0")"
DEMO=false
LAUNCH=true
INSTALL=false
CONFIGURATION=debug
for OPTION in "$@"; do
    case "$OPTION" in
      --demo) DEMO=true ;;
      --build-only) LAUNCH=false ;;
      --install) INSTALL=true ;;
      --release) CONFIGURATION=release ;;
      *) echo "Usage: sh run-app.sh [--demo] [--build-only] [--install] [--release]" >&2; exit 1 ;;
    esac
done
# A missing identity must never silently turn a daily-use build back into an
# ad-hoc build. Set up/recover signing before spending time compiling.
SIGNING_DIR="${LEDGER_SIGNING_DIR:-$HOME/Library/Application Support/LedgerSigning}"
if [ ! -f "$SIGNING_DIR/ready" ]; then
    echo "Run sh Scripts/setup-signing.sh once before building Ledger. Existing signing identities must be recovered, not regenerated." >&2
    exit 1
fi
mkdir -p .build/cache
# Packaging shares compiler/icon outputs and must not run twice concurrently.
mkdir .build/ledger-package.lock 2>/dev/null || { echo "Another Ledger build is active; retry when it finishes." >&2; exit 1; }
PACKAGE_DIR=""
cleanup() {
    if [ -n "$PACKAGE_DIR" ]; then rm -rf "$PACKAGE_DIR"; fi
    rmdir .build/ledger-package.lock
}
trap cleanup EXIT
export CLANG_MODULE_CACHE_PATH="$PWD/.build/cache"
export SWIFT_MODULE_CACHE_PATH="$PWD/.build/cache"
swift build --disable-sandbox --configuration "$CONFIGURATION" --product ledger-app
sh Scripts/build-icon.sh
APP="$PWD/Ledger.app"
BUNDLE_ID="local.ledger.preview"
APP_NAME="Ledger"
if [ "$DEMO" = true ]; then
    APP="$PWD/LedgerDemo.app"
    BUNDLE_ID="local.ledger.demo"
    APP_NAME="Ledger Demo"
fi
APP_DEST="$APP"
# A fresh bundle identity prevents IconServices retaining a development build's
# placeholder icon after resources change. Runtime databases live elsewhere.
PACKAGE_DIR=$(mktemp -d "$PWD/.build/app-package.XXXXXX")
APP="$PACKAGE_DIR/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -X ".build/$CONFIGURATION/ledger-app" "$APP/Contents/MacOS/Ledger"
cp -X .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -X .build/IconAssets/Assets.car "$APP/Contents/Resources/Assets.car"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleExecutable</key><string>Ledger</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>37</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Finder may add bundle metadata after the first launch; it prevents signing.
# Package outside .build: its hidden flag can propagate to nested app bundles
# and make them disappear from the Full Disk Access app picker.
chflags nohidden "$APP"
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
sh Scripts/sign-app.sh "$APP" "$BUNDLE_ID"
sh Scripts/replace-app.sh "$APP" "$APP_DEST" "$BUNDLE_ID"
APP="$APP_DEST"
chflags nohidden "$APP"
if [ "$INSTALL" = true ]; then
    INSTALLED_APP="$HOME/Applications/$(basename "$APP_DEST")"
    sh Scripts/replace-app.sh "$APP" "$INSTALLED_APP" "$BUNDLE_ID"
    APP="$INSTALLED_APP"
    echo "Installed: $APP"
fi
if [ "$LAUNCH" = true ]; then
    if [ "$DEMO" = true ]; then
        open "$APP" --args --demo
    else
        open "$APP"
    fi
fi

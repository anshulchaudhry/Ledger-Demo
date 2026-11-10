#!/bin/sh
# Synthetic executables only. No Messages, privacy settings or Ledger storage.
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD
mkdir -p .build
WORK=$(mktemp -d "$ROOT/.build/signing-checks.XXXXXX")
cleanup() {
    if [ -f "$WORK/other-signing/identity.keychain-db" ]; then
        security delete-keychain "$WORK/other-signing/identity.keychain-db" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
ID=local.ledger.signing-check
make_app() {
    APP_PATH=$1
    RESULT=$2
    mkdir -p "$APP_PATH/Contents/MacOS"
    cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$ID</string>
<key>CFBundleExecutable</key><string>Check</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
    printf 'int main(void) { return %s; }\n' "$RESULT" > "$WORK/check.c"
    xcrun clang "$WORK/check.c" -o "$APP_PATH/Contents/MacOS/Check"
}
requirement() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'; }
make_app "$WORK/First.app" 0
make_app "$WORK/Second.app" 1
sh Scripts/sign-app.sh "$WORK/First.app" "$ID"
sh Scripts/sign-app.sh "$WORK/Second.app" "$ID"
FIRST=$(requirement "$WORK/First.app")
[ -n "$FIRST" ] && [ "$FIRST" = "$(requirement "$WORK/Second.app")" ]
[ "$(shasum -a 256 "$WORK/First.app/Contents/MacOS/Check" | cut -d ' ' -f 1)" != "$(shasum -a 256 "$WORK/Second.app/Contents/MacOS/Check" | cut -d ' ' -f 1)" ]
codesign --verify --strict --test-requirement "=$FIRST" "$WORK/Second.app"
sh Scripts/replace-app.sh "$WORK/First.app" "$WORK/Installed.app" "$ID"
sh Scripts/replace-app.sh "$WORK/Second.app" "$WORK/Installed.app" "$ID"
[ "$FIRST" = "$(requirement "$WORK/Installed.app")" ]
cmp "$WORK/Second.app/Contents/MacOS/Check" "$WORK/Installed.app/Contents/MacOS/Check"

# A different real certificate must not replace the identity previously approved.
LEDGER_SIGNING_DIR="$WORK/other-signing" sh Scripts/setup-signing.sh > "$WORK/setup.out"
make_app "$WORK/OtherSigner.app" 3
LEDGER_SIGNING_DIR="$WORK/other-signing" sh Scripts/sign-app.sh "$WORK/OtherSigner.app" "$ID"
if sh Scripts/replace-app.sh "$WORK/OtherSigner.app" "$WORK/Installed.app" "$ID" > "$WORK/other-signer.out" 2>&1; then
    echo "An unexpected signing certificate was accepted." >&2; exit 1
fi
cmp "$WORK/Second.app/Contents/MacOS/Check" "$WORK/Installed.app/Contents/MacOS/Check"

# A missing identity must fail without modifying the bundle or generating keys.
BEFORE=$(shasum -a 256 "$WORK/First.app/Contents/MacOS/Check")
if LEDGER_SIGNING_DIR="$WORK/no-identity" sh Scripts/sign-app.sh "$WORK/First.app" "$ID" > "$WORK/missing.out" 2>&1; then
    echo "Missing identity was accepted." >&2; exit 1
fi
[ ! -e "$WORK/no-identity" ]
[ "$BEFORE" = "$(shasum -a 256 "$WORK/First.app/Contents/MacOS/Check")" ]

# A new ad-hoc signature is never an acceptable update.
make_app "$WORK/Adhoc.app" 2
codesign --force --sign - "$WORK/Adhoc.app"
if sh Scripts/replace-app.sh "$WORK/Adhoc.app" "$WORK/Installed.app" "$ID" > "$WORK/adhoc.out" 2>&1; then
    echo "Ad-hoc update was accepted." >&2; exit 1
fi
cmp "$WORK/Second.app/Contents/MacOS/Check" "$WORK/Installed.app/Contents/MacOS/Check"

# Migrating an old ad-hoc build once keeps the stable identity thereafter.
ditto --norsrc --noextattr "$WORK/Adhoc.app" "$WORK/Legacy.app"
sh Scripts/replace-app.sh "$WORK/First.app" "$WORK/Legacy.app" "$ID"
[ "$FIRST" = "$(requirement "$WORK/Legacy.app")" ]

# Corrupt and wrong-bundle updates leave the installed app intact.
ditto --norsrc --noextattr "$WORK/First.app" "$WORK/Corrupt.app"
printf 'corrupted' >> "$WORK/Corrupt.app/Contents/MacOS/Check"
if sh Scripts/replace-app.sh "$WORK/Corrupt.app" "$WORK/Installed.app" "$ID" > "$WORK/corrupt.out" 2>&1; then
    echo "Corrupt update was accepted." >&2; exit 1
fi
if sh Scripts/replace-app.sh "$WORK/First.app" "$WORK/Installed.app" local.ledger.demo > "$WORK/wrong-id.out" 2>&1; then
    echo "Wrong bundle identity was accepted." >&2; exit 1
fi
cmp "$WORK/Second.app/Contents/MacOS/Check" "$WORK/Installed.app/Contents/MacOS/Check"

# Force the final installed-bundle verification to fail and prove rollback.
mkdir "$WORK/tools"
cat > "$WORK/tools/codesign" <<'SH'
#!/bin/sh
if [ "$#" -eq 4 ] && [ "$1" = --verify ] && [ "$4" = "$LEDGER_CHECK_DESTINATION" ]; then
    exit 1
fi
if [ "$#" -eq 3 ] && [ "$1" = --verify ] && [ "$3" = "$LEDGER_CHECK_DESTINATION" ]; then
    exit 1
fi
exec /usr/bin/codesign "$@"
SH
chmod 700 "$WORK/tools/codesign"
if PATH="$WORK/tools:$PATH" LEDGER_CHECK_DESTINATION="$WORK/Installed.app" \
    sh Scripts/replace-app.sh "$WORK/First.app" "$WORK/Installed.app" "$ID" > "$WORK/rollback.out" 2>&1; then
    echo "An induced install verification failure was ignored." >&2; exit 1
fi
cmp "$WORK/Second.app/Contents/MacOS/Check" "$WORK/Installed.app/Contents/MacOS/Check"
codesign --verify --strict "$WORK/Installed.app"
echo "Signing checks passed: stable identity across changed builds; certificate-change rejection; missing-key/ad-hoc/corrupt/wrong-app protection; legacy migration and failed-install rollback."

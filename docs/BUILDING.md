# Build and install Ledger

Use macOS 14 or later and an Xcode installation with Swift 6. Run these commands from the repository root. The scripts use Apple's system tools and have no third-party dependencies.

## Build for your Mac

Create a local signing identity once on each Mac, then choose an app.

```sh
sh Scripts/setup-signing.sh
sh run-app.sh --demo --release --install
```

For the Messages-enabled app, run `sh run-app.sh --release --install` instead. Omit `--install` to keep the bundle in the source folder. Add `--build-only` to skip launching. The default build configuration is debug and `--release` selects the optimized build.

The local identity is stored under `~/Library/Application Support/LedgerSigning`. Keep that directory private and retain it between builds. The install script verifies the signing identity before replacing an app. Quit a running copy before updating it.

## Messages and local storage

Ledger Demo has its own app identity and stores fictional data under `~/Library/Application Support/LedgerDemo`. It cannot open Apple Messages.

Ledger stores extracted financial data under `~/Library/Application Support/Ledger`. To import from Apple Messages, open **System Settings → Privacy & Security → Full Disk Access** and enable the installed `~/Applications/Ledger.app`. Reopen Ledger and select **Import & status** or **Refresh now**. Apple Messages is opened read-only. Original messages are fetched on demand. Ledger saves no full SMS text in its transaction database.

## Verify and package

```sh
sh run-tests.sh
sh Tests/SigningChecks.sh
sh run-app.sh --demo --release --build-only
sh run-app.sh --release --build-only
```

The local build identity is for the Mac that created it. For a downloadable Demo, use an Apple Developer ID Application identity and an Apple notarization profile saved with `notarytool`. The packaging script builds the Demo, signs a staging copy for distribution, waits for notarization, staples the ticket, and writes a ZIP to `.build/dist`.

```sh
sh Scripts/package-demo-release.sh 'Developer ID Application: Your Name (TEAMID)' ledger-demo
```

The ZIP is built for the Mac's native architecture. Publish the ZIP for each architecture that you build and verify. Apple documents [Developer ID signing](https://developer.apple.com/developer-id/) and [notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

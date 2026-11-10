# Ledger

**A local spending journal for macOS.** Ledger turns supported bank SMS in Apple Messages into searchable transactions and monthly spending summaries. Ledger Demo gives you the same interface with fictional data, ready to explore without connecting a bank account or giving the app access to Messages.

<img src="Resources/AppIcon/ledger-wallet.png" width="128" alt="Ledger’s Everyday Wallet icon">

## Try Ledger Demo

**Version 0.4.0 · macOS 14 or later**

Open **Releases** for the Demo preview. The source build needs Xcode with Swift 6. After downloading and extracting the source, open Terminal in the extracted folder and run:

```sh
sh Scripts/setup-signing.sh
sh run-app.sh --demo --release --install
```

The first command creates a local signing identity on your Mac. The second builds and opens **Ledger Demo**, with a copy in `~/Applications`. Demo uses 130 fictional SMS examples. It works offline and never opens Apple Messages. [Build and installation details](docs/BUILDING.md)

## What you can do

- **See monthly spending** and open the transactions behind any category or total.
- **Search and filter transactions**, review uncertain payments, and save corrections or merchant rules.
- **Link two receipts for one card payment** and open both originals from the linked record.
- **Refresh on demand** or select a receipt date range. Data status shows saved transaction dates and recorded scan ranges.

The [Demo testing guide](docs/DEMO_TEST_GUIDE.md) walks through sample refreshes, duplicate payments, batch review, and light and dark layouts.

## Use Ledger with your own SMS

Build **Ledger** instead of Ledger Demo using `sh run-app.sh --release --install` after setting up local signing. Ledger reads supported Axis Bank, ICICI Bank, and IDFC FIRST Bank SMS synced to Apple Messages. Enable **Full Disk Access** for your installed Ledger app before the first import. [Setup and privacy details](docs/BUILDING.md)

Imports are manual. **Refresh now** checks for new receipts, with a 48-hour overlap for late arrivals. **Import & status** lets you choose an inclusive receipt-date range in Asia/Kolkata. The default starts August 1, 2026 and ends today. Only confirmed expenses enter spending totals. Transfers, card payments, and refunds are shown separately.

Ledger stores extracted transactions, edits, and rules on your Mac. The original SMS is read on demand and stays in Messages. Demo uses a separate local database. Both apps work without a cloud account, analytics, or a backend.

## Development

The app uses SwiftUI, Foundation, and SQLite. Run the fictional regression suite with `sh run-tests.sh`. See the [build guide](docs/BUILDING.md) for test commands, signing, and packaging.

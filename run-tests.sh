#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build/cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/cache"
export SWIFT_MODULE_CACHE_PATH="$PWD/.build/cache"
swiftc -package-name LedgerPOC -D LEDGER_TESTING -lsqlite3 Sources/LedgerCore/*.swift Sources/LedgerPOC/LedgerPOC.swift Sources/LedgerPOC/PrivateReview.swift Tests/*.swift -o .build/ledger-synthetic-checks
.build/ledger-synthetic-checks

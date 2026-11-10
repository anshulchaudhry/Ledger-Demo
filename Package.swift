// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LedgerPOC",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ledger-poc", targets: ["LedgerPOC"]),
        .executable(name: "ledger-app", targets: ["LedgerApp"]),
    ],
    targets: [
        .target(name: "LedgerCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "LedgerPOC", dependencies: ["LedgerCore"]),
        .executableTarget(name: "LedgerApp", dependencies: ["LedgerCore"]),
    ]
)

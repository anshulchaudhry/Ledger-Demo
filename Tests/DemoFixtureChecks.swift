import Foundation

func demoFixtureChecks() throws {
    let messages = FictionalMessages.all
    try check(messages.count >= 125 && Set(messages.map(\.guid)).count == messages.count,
              "Demo provides a substantial, repeatable set of fictional messages")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-demo-fixtures-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransactionStore(url: directory.appendingPathComponent("demo.sqlite"))
    let initial = try store.ingest(messages)
    let records = try store.load()
    try check(initial.inserted >= 100 && initial.existing == 1 && initial.unparsed == 4,
              "Demo seed exercises same-bank redelivery and skipped bank notices")
    try check(records.filter { $0.merchant == "Fictional Duplicate Cafe" }.count == 2,
              "Demo distinguishes separate bank records that share a reference")
    let october = LedgerMonth(containing: Importer.endExclusive.addingTimeInterval(-1))
    for offset in -2...0 {
        let summary = try MonthlySummary(month: october.offset(offset), records: records)
        try check(summary.total(.expenses).count > 0 && summary.total(.refunds).count > 0 && summary.total(.transfers).count > 0,
                  "Demo monthly totals have mixed transaction types across several months")
    }
    try check(try store.recipientReviewGroups().contains { $0.recipient == "Juniper Studio" && $0.records.count >= 2 },
              "Demo supports a meaningful batch review")
    try check(try store.cardPaymentDuplicates(messages: messages).count == 1, "Demo has an unambiguous pair of card receipts to link")
    let november = october.offset(1)
    let window = ImportWindow(from: ImportWindow.defaultStart, through: november.start.addingTimeInterval(9 * 24 * 3600))!
    let refreshed = try store.ingest(messages, window: window, isRefresh: true)
    let repeated = try store.ingest(messages, window: window, isRefresh: true)
    try check(refreshed.inserted == 6 && repeated.inserted == 0, "Demo refresh adds the November fixtures once")
}

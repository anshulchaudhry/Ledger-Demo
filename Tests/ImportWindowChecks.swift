import Foundation
import SQLite3

func importWindowChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-window-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("fictional-messages.sqlite")
    let storeURL = directory.appendingPathComponent("Ledger/transactions.sqlite")
    let calendar = TransactionRecord.calendar
    let august = ImportWindow.defaultStart
    let november = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10))!
    let window = ImportWindow(from: august.addingTimeInterval(3600), through: november.addingTimeInterval(7200))!
    let lastSecond = window.endExclusive.addingTimeInterval(-1)
    try check(window.start == august && window.through == november && ImportWindow(from: november, through: august) == nil,
              "date inputs normalize to inclusive Kolkata days and reject reversed dates")
    let older = message("AX-AXISBK", "INR 15 spent at FICTIONAL JULY STORE. Ref TESTJULY", "old-july", august.addingTimeInterval(-1))
    let first = message("AX-AXISBK", "INR 20 spent at FICTIONAL AUGUST STORE on 31/07/26. Ref TESTFIRST", "first-august", august)
    let current = message("AX-AXISBK", "INR 21 spent at FICTIONAL NOVEMBER STORE. Ref TESTLAST", "", lastSecond)
    let tomorrow = message("AX-AXISBK", "INR 22 spent at FICTIONAL FUTURE STORE. Ref TESTNEXT", "future", window.endExclusive)
    let sources = [older, first, current, tomorrow]
    let epoch = Date(timeIntervalSince1970: 978307200)
    try withSyntheticSQL(sourceURL.path) { database in
        try testSQL(database, "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT)")
        try testSQL(database, "CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, handle_id INTEGER, text TEXT, attributedBody BLOB, date INTEGER, service TEXT, is_from_me INTEGER)")
        try testSQL(database, "INSERT INTO handle VALUES (1,'AX-AXISBK')")
        for (index, source) in sources.enumerated() {
            let seconds = Int64(source.receivedAt.timeIntervalSince(epoch))
            let timestamp = index.isMultiple(of: 2) ? seconds : seconds * 1_000_000_000
            try testSQL(database, "INSERT INTO message VALUES (\(index + 1),'\(source.guid)',1,'\(source.text)',NULL,\(timestamp),'SMS',0)")
        }
    }
    let imported = try MessagesReader.read(path: sourceURL.path, window: window)
    try check(Set(imported.map(\.text)) == Set([first.text, current.text]), "reader includes both date boundaries and excludes July and tomorrow")
    let store = try TransactionStore(url: storeURL)
    _ = try store.ingest([older])
    let result = try store.ingest(sources, window: window)
    let rows = try store.load()
    try check(result.inserted == 2 && rows.count == 3 && rows.contains { $0.amountPaise == 1500 },
              "store enforces receipt boundaries and keeps older saved transactions")
    try check(rows.first { $0.amountPaise == 2000 }.map { $0.date < august } == true,
              "receipt-date selection stays independent of the transaction date in the SMS")

    let narrow = ImportWindow(from: november, through: november)!
    try withSyntheticSQL(storeURL.path) { database in
        try testSQL(database, "CREATE TRIGGER fail_scan BEFORE INSERT ON import_scans BEGIN SELECT RAISE(ABORT,'fictional failed scan'); END")
    }
    let additional = message("AX-AXISBK", "INR 40 spent at FICTIONAL EXTRA STORE. Ref TESTEXTRA", "new", november)
    do { _ = try store.ingest([additional], window: narrow); throw CheckFailure.failed("failed scan must be reported") }
    catch StoreError.operationFailed { }
    try check(try store.load() == rows && store.importHistory().lastScan?.window == window,
              "failed import keeps both prior history and saved rows intact")
    try withSyntheticSQL(storeURL.path) { try testSQL($0, "DROP TRIGGER fail_scan") }
    try check(try store.ingest(sources, window: narrow).inserted == 0, "narrow repeat import is idempotent")
    let reopened = try TransactionStore(url: storeURL)
    let history = try reopened.importHistory()
    try check(history.lastScan?.window == narrow && history.lastScan?.result.existing == 1 && history.windows == [window],
              "successful receipt scans and counts survive restart and overlapping ranges merge")
    try check(try history.sourceWindows.contains { lookupWindow in
        try MessagesReader.originalMessage(path: sourceURL.path, source: ImportIdentity.source(current), window: lookupWindow)?.text == current.text
    }, "a saved November source without a GUID remains available after narrowing the window")

    let fullReceipt = message("AX-AXISBK", "INR 50 spent at FICTIONAL STORE. Ref TESTALIAS", "valid-alias", august)
    let lateDelivery = message(fullReceipt.sender, fullReceipt.text, "late-alias", november)
    _ = try store.ingest([fullReceipt, lateDelivery], window: window)
    let changedDelivery = message(lateDelivery.sender, "Your account will be debited for INR 50 tomorrow.", lateDelivery.guid, november)
    let partial = try store.ingest([changedDelivery], window: narrow)
    try check(partial.excluded == 0 && (try store.load()).contains { $0.amountPaise == 5000 },
              "a narrow scan does not exclude a payment whose other receipt was outside the scan")
}

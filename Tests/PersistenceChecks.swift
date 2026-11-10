import Foundation
import SQLite3

// All fixtures are fictional. Test failures contain check names only.
func persistenceChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-store-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let first = message("AX-AXISBK", "INR 125.50 spent at SYNTHETIC SHOP. Ref TEST000001", "stable-guid")
    let redelivery = message("AX-AXISBK", first.text, "redelivered-guid", first.receivedAt.addingTimeInterval(90))
    let uncertain = message("JD-IDFCFB", "INR 99 debited and credited. Ref TEST000002", "uncertain-guid")
    let unknownType = message("VM-ICICIB", "INR 23 debited from A/c XX0003. Ref TEST000003", "unknown-type")
    let noGUID = message("AX-AXISBK", "INR 18 spent at SYNTHETIC CAFE", "")
    let noGUIDRepeat = message("AX-AXISBK", "INR 18   spent at SYNTHETIC CAFE", "", noGUID.receivedAt.addingTimeInterval(1))
    let sameReferenceDifferentFlow = message("AX-AXISBK", "INR 125.50 refunded from SYNTHETIC REFUND. Ref TEST000001", "refund-guid")
    var correction: TransactionRecord!
    var deletedID = ""
    do {
        let store = try TransactionStore(url: url)
        try check(try store.load().isEmpty, "new empty store")
        let result = try store.ingest([first, redelivery, first, uncertain, unknownType, noGUID, noGUIDRepeat,
            sameReferenceDifferentFlow, message("FRIEND", first.text), message("AX-AXISBK", first.text, "old", Importer.start.addingTimeInterval(-1)),
            message("AX-AXISBK", "Balance INR 100"),
            message("AX-AXISBK", "Credit card payment of INR 400 is due tomorrow. Ignore if paid.")])
        try check(result.candidates == 10 && result.inserted == 5 && result.existing == 3 && result.unparsed == 2, "persistent duplicate policy")
        let rows = try store.load()
        try check(rows.count == 5, "all imported rows including uncertain")
        try check(rows.filter(\.needsReview).count == 2, "review state includes direction and type")
        try check(rows.filter(\.isConfirmedExpense).count == 2, "future spending gate excludes uncertain and refund")
        correction = rows.first { $0.amountPaise == 12550 && $0.direction == .debit }!
        try check(try store.sources(id: correction.id).count == 2, "redelivery source aliases")
        correction.amountPaise = 20001
        correction.merchant = "Corrected fictional recipient"
        correction.date = Importer.start.addingTimeInterval(86400)
        correction.bank = .icici
        correction.direction = .credit
        correction.type = .incomingPayment
        correction.dateFromSMS = false
        try store.save(correction)
        var invalid = correction!
        invalid.type = .expense
        do { try store.save(invalid); throw CheckFailure.failed("reject incompatible correction") }
        catch StoreError.invalidRecord { }
        invalid = correction
        invalid.amountPaise = 0
        do { try store.save(invalid); throw CheckFailure.failed("reject zero correction") }
        catch StoreError.invalidRecord { }
        deletedID = rows.first { $0.amountPaise == 9900 }!.id
        try store.delete(id: deletedID)
    }
    do {
        let reopened = try TransactionStore(url: url)
        let repeatResult = try reopened.ingest([first, redelivery, uncertain, unknownType, noGUID, noGUIDRepeat, sameReferenceDifferentFlow])
        try check(repeatResult.inserted == 0 && repeatResult.existing == 7, "restart and reimport do not recreate rows")
        let rows = try reopened.load()
        let saved = rows.first { $0.id == correction.id }!
        correction.manuallyEdited = true
        try check(saved == correction, "all correction fields preserved after restart and import")
        try check(!rows.contains { $0.id == deletedID }, "deleted row remains hidden")
        try check(try reopened.sources(id: deletedID).count == 1, "deleted source identity retained")
        // A source GUID still matches even if upstream parser fields change.
        let changedSource = message("AX-AXISBK", "INR 333 spent at CHANGED SOURCE. Ref CHANGED001", first.guid)
        try check(try reopened.ingest([changedSource]).inserted == 0, "immutable GUID protects correction")
        try check(try reopened.load().first { $0.id == correction.id } == correction, "changed source does not overwrite manual fields")
        let changedDeleted = message("JD-IDFCFB", "INR 888 spent at CHANGED SOURCE. Ref CHANGED002", uncertain.guid)
        try check(try reopened.ingest([changedDeleted]).inserted == 0, "immutable deleted identity suppresses changed source")
        try check(try reopened.load().count == 4, "no tombstone resurrection")
    }
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
    try check(permissions == 0o600 && directoryPermissions == 0o700, "private store permissions")
    let bytes = try Data(contentsOf: url)
    try check(bytes.range(of: Data(first.text.utf8)) == nil, "store does not contain full original SMS")
    try check(bytes.range(of: Data("debited and credited".utf8)) == nil, "deleted SMS never persisted")
    try check(bytes.range(of: Data("SYNTHETIC SHOP".utf8)) == nil, "secure update clears previous merchant")

    // Verify whole-batch rollback, including alias tables, on a write failure.
    try withSyntheticSQL(url.path) { database in
        try testSQL(database, "CREATE TRIGGER reject_test BEFORE INSERT ON transactions WHEN NEW.amount_paise=77700 BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
    }
    let newMessage = message("AX-AXISBK", "INR 666 spent at ATOMIC SHOP. Ref ATOMIC0001", "atomic-1")
    do {
        let store = try TransactionStore(url: url)
        do {
            _ = try store.ingest([newMessage, message("AX-AXISBK", "INR 777 spent at ATOMIC SHOP. Ref ATOMIC0002", "atomic-2")])
            throw CheckFailure.failed("atomic import should fail")
        } catch StoreError.operationFailed { }
        try check(try store.load().count == 4, "batch failure rolls back records")
        try check(try store.ingest([newMessage]).inserted == 1, "batch failure rolls back identities")
    }
    try withSyntheticSQL(url.path) { try testSQL($0, "PRAGMA user_version=999") }
    do { _ = try TransactionStore(url: url); throw CheckFailure.failed("future schema should fail") }
    catch StoreError.unsupportedVersion { }
    try check(TransactionRecord.paise(from: "123.45") == 12345, "exact paise")
    for invalid in ["0", "-1", "1.001", "NaN", "1000000000000", "1e3"] {
        try check(TransactionRecord.paise(from: invalid) == nil, "invalid amount rejected")
    }
}

func withSyntheticSQL(_ path: String, _ action: (OpaquePointer) throws -> Void) throws {
    var handle: OpaquePointer?
    try check(sqlite3_open(path, &handle) == SQLITE_OK, "synthetic open")
    guard let handle else { throw CheckFailure.failed("synthetic handle") }
    defer { sqlite3_close(handle) }
    try action(handle)
}
func testSQL(_ database: OpaquePointer, _ sql: String) throws {
    try check(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK, "synthetic statement")
}

func sourceRetrievalChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-source-check-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("fictional-messages.sqlite")
    let storeURL = directory.appendingPathComponent("Ledger/transactions.sqlite")
    let timestamp = Int64(Importer.start.addingTimeInterval(60).timeIntervalSince(Date(timeIntervalSince1970: 978307200)))
    let plain = "INR 20 spent at SYNTHETIC SHOP. Ref SOURCE0001"
    let attributed = "INR 30 refunded from SYNTHETIC CAFE. Ref SOURCE0002"
    try withSyntheticSQL(sourceURL.path) { database in
        try testSQL(database, "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT)")
        try testSQL(database, "CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, handle_id INTEGER, text TEXT, attributedBody BLOB, date INTEGER, service TEXT, is_from_me INTEGER)")
        try testSQL(database, "INSERT INTO handle VALUES (1,'AX-AXISBK'), (2,'PERSON')")
        try testSQL(database, "INSERT INTO message VALUES (1,'guid-plain',1,'\(plain)',NULL,\(timestamp),'SMS',0)")
        let blob = typedBody(attributed).map { String(format: "%02x", $0) }.joined()
        try testSQL(database, "INSERT INTO message VALUES (2,'guid-attributed',1,NULL,X'\(blob)',\(timestamp * 1_000_000_000),'SMS',0)")
        try testSQL(database, "INSERT INTO message VALUES (3,NULL,1,'INR 40 spent at NO GUID SHOP',NULL,\(timestamp),'SMS',0)")
        try testSQL(database, "INSERT INTO message VALUES (4,'personal',2,'FICTIONAL PERSONAL TEXT',NULL,\(timestamp),'SMS',0)")
        try testSQL(database, "INSERT INTO message VALUES (5,'outgoing',1,'INR 50 spent at OUTGOING SHOP',NULL,\(timestamp),'SMS',1)")
    }
    let before = try Data(contentsOf: sourceURL)
    let messages = try MessagesReader.read(path: sourceURL.path)
    let store = try TransactionStore(url: storeURL)
    try check(try store.ingest(messages).inserted == 3, "synthetic Messages to store integration")
    try check(messages.count == 3, "personal and outgoing messages excluded")
    for message in messages {
        try check(try MessagesReader.original(path: sourceURL.path, source: ImportIdentity.source(message)) == message.text, "plain attributed and no-GUID retrieval")
        try check(try MessagesReader.originalMessage(path: sourceURL.path, source: ImportIdentity.source(message))?.sender == message.sender, "source review uses original sender metadata")
    }
    try check(try Data(contentsOf: sourceURL) == before, "import and retrieval leave source bytes unchanged")
    let row = try store.load().first { $0.amountPaise == 2000 }!
    var correction = row
    correction.merchant = "Fictional correction"
    correction.bank = .idfc
    try store.save(correction)
    let identity = try store.sources(id: row.id)[0]
    try check(try MessagesReader.original(path: sourceURL.path, source: identity) == plain, "source retrieval independent of edited fields")
    try withSyntheticSQL(sourceURL.path) { try testSQL($0, "DELETE FROM message WHERE guid='guid-plain'") }
    try check(try MessagesReader.original(path: sourceURL.path, source: identity) == nil, "missing original handled")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sourceURL.path)
    do {
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceURL.path) }
        do { _ = try MessagesReader.original(path: sourceURL.path, source: identity); throw CheckFailure.failed("denied source access") }
        catch DatabaseError.unavailable { }
    }
    let absentPath = directory.appendingPathComponent("not-created.sqlite").path
    do { _ = try MessagesReader.original(path: absentPath, source: identity); throw CheckFailure.failed("missing source database") }
    catch DatabaseError.unavailable { }
    try check(!FileManager.default.fileExists(atPath: absentPath), "read-only open never creates source")
    let unsupported = directory.appendingPathComponent("unsupported.sqlite").path
    try withSyntheticSQL(unsupported) { try testSQL($0, "CREATE TABLE other (id INTEGER)") }
    do { _ = try MessagesReader.original(path: unsupported, source: identity); throw CheckFailure.failed("unsupported source schema") }
    catch DatabaseError.unsupportedSchema { }
    let storedBytes = try Data(contentsOf: storeURL)
    try check(storedBytes.range(of: Data(plain.utf8)) == nil && storedBytes.range(of: Data(attributed.utf8)) == nil, "integration never stores full SMS")
}

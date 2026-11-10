import Foundation
import SQLite3

enum CheckFailure: Error { case failed(String) }

func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
    if try !condition() { throw CheckFailure.failed(name) }
}

func message(_ sender: String, _ body: String, _ guid: String = UUID().uuidString,
             _ date: Date = Importer.start.addingTimeInterval(3600)) -> Message {
    Message(guid: guid, sender: sender, text: body, receivedAt: date,
            service: "SMS", isFromMe: false)
}

func typedBody(_ text: String) -> Data {
    let payload = Array(text.utf8)
    var bytes = [UInt8]([4, 11]) + Array("streamtyped".utf8) + [0x01, 0x2b]
    if payload.count < 128 {
        bytes.append(UInt8(payload.count))
    } else {
        bytes += [0x81, UInt8(payload.count & 0xff), UInt8((payload.count >> 8) & 0xff)]
    }
    return Data(bytes + payload)
}

func parserChecks() throws {
    guard let axis = Parser.parse(message("AX-AXISBK", "INR 1,234.50 debited from A/c XX1234 at COFFEE SHOP on 30-Oct-26. Ref ABC123456")) else {
        throw CheckFailure.failed("Axis parse")
    }
    try check(axis.bank == .axis, "Axis bank")
    try check(axis.direction == .debit, "Axis direction")
    try check(axis.amountPaise == 123450, "Axis amount")
    try check(axis.merchant == "COFFEE SHOP", "Axis merchant")
    try check(axis.maskedInstrument == "XX1234", "Axis masked account")
    try check(axis.reference == "ABC123456", "Axis reference")
    try check(axis.dateFromSMS, "date extracted from SMS")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = Importer.timeZone
    try check(calendar.component(.day, from: axis.transactionAt) == 30, "transaction day")
    try check(calendar.component(.year, from: axis.transactionAt) == 2026, "transaction year")

    guard let icici = Parser.parse(message("VM-ICICIB", "Rs.500.00 credited to your account XX9988 from FRIEND. Ref CDE123456")) else {
        throw CheckFailure.failed("ICICI parse")
    }
    try check(icici.bank == .icici, "ICICI bank")
    try check(icici.direction == .credit, "ICICI direction")
    try check(icici.amountPaise == 50000, "ICICI amount")

    guard let idfc = Parser.parse(message("JD-IDFCFB", "INR 750 paid to GROCERY MART via UPI. UPI Ref 123456789012")) else {
        throw CheckFailure.failed("IDFC parse")
    }
    try check(idfc.bank == .idfc, "IDFC bank")
    try check(idfc.direction == .debit, "IDFC direction")
    try check(idfc.reference == "123456789012", "IDFC reference")
    let dualVerb = tryUnwrapIDFC(message(
        "JD-IDFCFB",
        "Your A/c XX1234 debited by Rs. 1,100.00 on 29/10/26; TEST RECIPIENT credited. RRN 123456789012. Available balance Rs. 2,000.00. Team IDFC FIRST Bank"
    ))
    try check(dualVerb.direction == .debit, "IDFC own-account debit")
    try check(dualVerb.resolvedIDFCDualVerbDebit, "IDFC rule marked")
    try check(dualVerb.merchant == "TEST RECIPIENT", "IDFC recipient")
    try check(dualVerb.reference == "123456789012", "IDFC RRN")
    try check(Importer.summarize([message(
        "JD-IDFCFB",
        "Your A/c XX1234 debited by Rs. 1,100.00 on 29/10/26; TEST RECIPIENT credited. RRN 123456789012"
    )]).resolvedIDFCDualVerbDebits == 1, "IDFC rule aggregate")
    let otherDualVerb = tryUnwrapIDFC(message(
        "JD-IDFCFB", "INR 100 debited and credited to your A/c XX1234. RRN 987654321000"
    ))
    try check(otherDualVerb.direction == .uncertain, "other dual-verb text remains uncertain")
    try check(Parser.parse(message("AX-AXISBK", "Balance INR 900")) == nil, "balance is not a transaction")
    try check(Parser.parse(message("AX-AXISBK", "INR 100 spent at TEST SHOP"))?.type == .expense, "expense type")
    try check(Parser.parse(message("AX-AXISBK", "INR 100 debited for NEFT transfer"))?.type == .transfer, "transfer type")
    try check(Parser.parse(message("AX-AXISBK", "INR 100 debited for credit card bill"))?.type == .cardPayment, "card payment type")
    let reminder = message("AX-AXISBK", "Payment of INR 840.50 for Axis Bank Credit Card no. XX0001 is due on 18-10-26 with minimum amount due INR 120. Ignore if paid.")
    try check(Parser.parse(reminder) == nil, "card bill reminder is not a completed payment")
    try check(Parser.rejectionReason(reminder) == "cardBillReminder", "reminder diagnostic has no financial fields")
    let reminderSummary = Importer.summarize([reminder])
    try check(reminderSummary.parsedTransactions == 0 && reminderSummary.unparsedByReason["cardBillReminder"] == 1, "reminder never counted as transaction")
    try check(Parser.parse(message("VM-ICICIB", "Your credit card amount due is INR 900. Disregard if already paid.")) == nil, "conditional paid reminder variant")
    try check(Parser.parse(message("JD-IDFCFB", "Your credit card payment due is INR 500.")) == nil, "reminder without conditional verb")
    let completedBill = Parser.parse(message("AX-AXISBK", "INR 600 debited for credit card bill payment. Remaining minimum amount due INR 50."))
    try check(completedBill?.type == .cardPayment && completedBill?.direction == .debit, "posted bill payment with remaining due stays card payment")
    try check(Parser.parse(message("AX-AXISBK", "INR 100 refunded from TEST SHOP"))?.type == .refund, "refund type")
    try check(Parser.parse(message("AX-AXISBK", "INR 100 credited from TEST PERSON"))?.type == .incomingPayment, "incoming payment type")
    try check(Parser.parse(message("AX-AXISBK", "INR 100 debited from A/c XX1234"))?.needsReview == true, "unknown type needs review")
}

func cardPaymentReceiptChecks() throws {
    // Fictional amounts, dates, identifiers and source IDs only.
    let body = "Payment of INR 840.50 has been received towards your Axis Bank Credit Card XX0001 on 20-10-26 - Axis Bank"
    let receipt = message("AX-AXISBK", body, "fictional-card-receipt")
    guard let parsed = Parser.parse(receipt) else { throw CheckFailure.failed("card bill receipt parses") }
    try check(parsed.type == .cardPayment && parsed.direction == .debit && !parsed.needsReview, "issuer receipt is card payment money out")
    try check(parsed.amountPaise == 84050 && parsed.maskedInstrument == "XX0001", "fictional receipt amount and masked card")
    try check(parsed.merchant == "Credit card payment", "card bill receipt recipient")
    try check(parsed.dateFromSMS && TransactionRecord.calendar.component(.day, from: parsed.transactionAt) == 20, "receipt transaction date")
    let compact = body.replacingOccurrences(of: "has been received", with: "received")
    try check(Parser.parse(message("AX-AXISBK", compact))?.type == .cardPayment, "receipt without auxiliary verb")
    for phrase in ["will be received", "has not been received"] {
        let other = body.replacingOccurrences(of: "has been received", with: phrase)
        try check(Parser.parse(message("AX-AXISBK", other)) == nil, "future negative or failed receipt is not a transaction")
    }
    try check(Parser.parse(message("AX-AXISBK", body + ". Payment failed.")) == nil, "failed receipt is not a transaction")
    let reversed = body + ". Payment reversed."
    try check(Parser.parse(message("AX-AXISBK", reversed))?.type == .refund, "reversed receipt remains a reversal not a card payment")
    try check(Parser.parse(message("AX-AXISBK", "Payment of INR 840.50 has been received from FICTIONAL PERSON on 20-10-26"))?.type == .incomingPayment, "ordinary incoming payment remains incoming")
    try check(Parser.parse(message("AX-AXISBK", "INR 840.50 refunded to your Axis Bank Credit Card XX0001 on 20-10-26"))?.type == .refund, "card purchase refund remains refund")
    let summary = Importer.summarize([receipt])
    try check(summary.byTransactionType["cardPayment"] == 1 && summary.byDirection["credit"] == nil, "receipt aggregate not incoming money")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-card-receipt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    do {
        let store = try TransactionStore(url: url)
        let repeated = message("AX-AXISBK", body, "fictional-receipt-redelivery", receipt.receivedAt)
        try check(try store.ingest([receipt, repeated]).inserted == 1, "card receipt duplicate handling")
        var row = try store.load()[0]
        try check(row.type == .cardPayment && row.direction == .debit && !row.isConfirmedExpense, "stored card payment excluded from spending")
        row.merchant = "Fictional manual correction"
        row.type = .transfer
        try store.save(row)
    }
    let reopened = try TransactionStore(url: url)
    try check(try reopened.ingest([receipt]).inserted == 0, "card receipt reimport does not duplicate")
    try check(try reopened.load()[0].type == .transfer, "receipt rule preserves a saved manual correction")
}

func tryUnwrapIDFC(_ value: Message) -> Transaction {
    guard let transaction = Parser.parse(value) else { fatalError("Synthetic IDFC parse failed") }
    return transaction
}

func aggregateChecks() throws {
    let body = "INR 42.00 debited at TEST STORE. Ref TXN123456"
    let messages = [
        message("AX-AXISBK", body, "one"),
        message("AX-AXISBK", body, "two"),
        message("AX-AXISBK", body, "one"),
        message("VM-ICICIB", "INR 100 debited and credited. Ref MIX123456"),
        message("JD-IDFCFB", "Your balance is INR 999"),
        message("FRIEND", "INR 30 debited at LUNCH"),
        message("AX-AXISBK", body, "old", Importer.start.addingTimeInterval(-1)),
        message("AX-AXISBK", body, "late", Importer.endExclusive),
    ]
    let summary = Importer.summarize(messages)
    try check(summary.candidateMessages == 5, "candidate count")
    try check(summary.parsedTransactions == 2, "parsed count")
    try check(summary.duplicateTransactions == 2, "duplicate count")
    try check(summary.unparsedCandidates == 1, "unparsed count")
    try check(summary.needsReview == 2, "review count includes uncertain type")
    try check(summary.byBank["Axis"] == 1, "bank aggregate")
    try check(summary.byDirection["uncertain"] == 1, "direction aggregate")
    try check(summary.unparsedByReason["noDirectionVerb"] == 1, "unparsed reason")
    try check(summary.unparsedByBank["IDFC FIRST"] == 1, "unparsed bank")
    try check(summary.uncertainByBank["ICICI"] == 1, "uncertain bank")
    try check(summary.uncertainVerbPairs["debited+credited"] == 1, "uncertain verb pair")
}

func attributedBodyChecks() throws {
    let short = "INR 20 debited at SHOP"
    try check(AttributedBodyDecoder.decode(typedBody(short)) == short, "short typed body")
    let unicode = "₹20 debited at SHOP"
    try check(AttributedBodyDecoder.decode(typedBody(unicode)) == unicode, "UTF-8 typed body")
    let long = "INR 20 debited at " + String(repeating: "SHOP", count: 40)
    try check(AttributedBodyDecoder.decode(typedBody(long)) == long, "long typed body")
    try check(AttributedBodyDecoder.decode(Data([4, 11, 0])) == nil, "truncated body rejected")
    try check(AttributedBodyDecoder.decode(Data([0, 1, 2])) == nil, "unknown body rejected")
}

func sqliteChecks() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-synthetic-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    var database: OpaquePointer?
    try check(sqlite3_open(path, &database) == SQLITE_OK, "create synthetic database")
    guard let database else { throw CheckFailure.failed("synthetic database handle") }
    func sql(_ statement: String) throws {
        try check(sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK, "synthetic SQL")
    }
    try sql("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT)")
    try sql("CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, handle_id INTEGER, text TEXT, attributedBody BLOB, date INTEGER, service TEXT, is_from_me INTEGER)")
    try sql("INSERT INTO handle VALUES (1, 'AX-AXISBK'), (2, 'PERSON')")
    let appleEpoch = Date(timeIntervalSince1970: 978307200)
    let inWindow = Int64(Importer.start.addingTimeInterval(60).timeIntervalSince(appleEpoch) * 1_000_000_000)
    let before = Int64(Importer.start.addingTimeInterval(-60).timeIntervalSince(appleEpoch) * 1_000_000_000)
    try sql("INSERT INTO message VALUES (1, 'a', 1, 'INR 20 debited at SHOP', NULL, \(inWindow), 'SMS', 0)")
    try sql("INSERT INTO message VALUES (2, 'b', 1, 'INR 20 debited at SHOP', NULL, \(before), 'SMS', 0)")
    try sql("INSERT INTO message VALUES (3, 'c', 2, 'INR 20 debited at SHOP', NULL, \(inWindow), 'SMS', 0)")
    try sql("INSERT INTO message VALUES (4, 'd', 1, NULL, NULL, \(inWindow), 'SMS', 0)")
    let blob = typedBody("INR 30 credited from FRIEND").map { String(format: "%02x", $0) }.joined()
    try sql("INSERT INTO message VALUES (5, 'e', 1, NULL, X'\(blob)', \(inWindow), 'SMS', 0)")
    try sql("INSERT INTO message VALUES (6, 'f', 1, NULL, X'000102', \(inWindow), 'SMS', 0)")
    sqlite3_close(database)
    let messages = try MessagesReader.read(path: path)
    try check(messages.count == 4, "SQL window and sender filter")
    let summary = Importer.summarize(messages)
    try check(summary.parsedTransactions == 2, "SQLite import")
    try check(summary.unparsedByReason["missingText"] == 2, "missing text diagnostic")
    try check(summary.recoveredAttributedBodies == 1, "attributed body recovery count")
    try check(summary.recoveredAttributedBodiesByBank["Axis"] == 1, "recovered body bank")
    try check(summary.missingTextByBank["Axis"] == 2, "missing text bank")
    try check(summary.undecodedAttributedBodies == 1, "undecodable body count")
}

func privateReviewChecks() throws {
    let senders = ["AX-AXISBK", "VM-ICICIB", "JD-IDFCFB"]
    var messages: [Message] = []
    for (bankIndex, sender) in senders.enumerated() {
        for index in 0..<14 {
            messages.append(message(sender, "INR \(100 + index) spent at SYNTHETIC SHOP. Ref TEST\(bankIndex)\(index + 10000)",
                                    "parsed-\(bankIndex)-\(index)"))
        }
        for index in 0..<7 {
            let text = index.isMultiple(of: 2) ? "Balance INR 1000" : "Account notice without a rupee amount"
            messages.append(message(sender, text, "unparsed-\(bankIndex)-\(index)"))
        }
    }
    for index in 0..<13 {
        messages.append(message("JD-IDFCFB",
                                "Your A/c XX1234 debited by Rs. 100 on 29/10/26; SYNTHETIC PERSON credited. RRN 123456\(index + 1000)",
                                "dual-\(index)"))
    }
    messages.append(message("JD-IDFCFB", "INR 100 debited and credited to your A/c XX1234. RRN 987654321000", "dual-uncertain"))

    let selected = ReviewSampler.select(messages)
    try check(selected.count == 55, "55-message sample")
    try check(selected.filter { $0.stratum == .parsed }.count == 30, "parsed quota")
    try check(selected.filter { $0.stratum == .unparsed }.count == 15, "unparsed quota")
    try check(selected.filter { $0.stratum == .dualVerb }.count == 10, "dual-verb quota")
    try check(selected.contains { $0.message.guid == "dual-uncertain" }, "uncertain dual-verb included")
    let quick = Array(selected.prefix(ReviewSampler.quickPass))
    try check(quick.count == 10, "quick checkpoint size")
    try check(quick.filter { $0.stratum == .parsed }.count == 6, "quick parsed mix")
    try check(quick.filter { $0.stratum == .unparsed }.count == 3, "quick unparsed mix")
    try check(quick.filter { $0.stratum == .dualVerb }.count == 1, "quick dual-verb mix")
    try check(Set(quick.map(\.bank)).count == 3, "quick pass includes every bank")
    try check(quick.contains { $0.message.guid == "dual-uncertain" }, "quick pass includes uncertain case")
    try check(ReviewSampler.select(messages).map(\.id) == selected.map(\.id), "stable sample")

    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-review-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = ReviewStore(url: temp.appendingPathComponent("review.json"))
    var state = try store.loadOrCreate(items: selected)
    guard let parsed = state.plan.first(where: { $0.stratum == .parsed }),
          let unparsed = state.plan.first(where: { $0.stratum == .unparsed }),
          let dual = state.plan.first(where: { $0.stratum == .dualVerb }) else {
        throw CheckFailure.failed("review strata")
    }
    state.decisions = [
        ReviewDecision(id: parsed.id, verdict: .correct, errors: [], actualType: parsed.predictedType),
        ReviewDecision(id: unparsed.id, verdict: .nonTransaction, errors: [], actualType: nil),
        ReviewDecision(id: dual.id, verdict: .incorrect, errors: [.type], actualType: .transfer),
    ]
    try store.save(state)
    let saved = try Data(contentsOf: store.url)
    let fileMode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
    try check(fileMode == 0o600, "private review file permissions")
    let savedText = String(decoding: saved, as: UTF8.self)
    try check(!savedText.contains("SYNTHETIC SHOP") && !savedText.contains("A/c XX1234"), "review state excludes message text")
    let report = ReviewReport(state: try store.load())
    try check(report.selected == 55 && report.reviewed == 3 && report.checkpointRemaining == 7, "resumable review counts")
    try check(!report.quickCheckpointComplete, "checkpoint remains open")
    try check(report.errorTypes["type"] == 1, "aggregate error type")
    try check(report.outcomesByStratum["unparsed.nonTransaction"] == 1, "sample outcome by stratum")
    let reportText = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    try check(!reportText.contains("SYNTHETIC") && !reportText.contains("XX1234"), "report excludes message text")
    try check(PrivateReview.safeTerminalText("OK\u{001B}[31m") == "OK�[31m", "terminal control characters escaped")

    // Simulate a review file created before the quick-checkpoint ordering.
    state.plan.sort { $0.id < $1.id }
    try store.save(state)
    let migrated = try store.loadOrCreate(items: selected)
    try check(migrated.plan.map(\.id) == selected.map(\.id), "old plan adopts quick-checkpoint order")
    try check(migrated.decisions.count == 3, "old answers survive plan reorder")
}

@main
struct SyntheticChecks {
    static func main() throws {
        try parserChecks()
        try merchantIntelligenceChecks()
        try axisIMPSPartyChecks()
        try categorizationCatalogChecks()
        try categorizationAutomaticChecks()
        try categorizationRollbackChecks()
        try merchantRuleChecks()
        try merchantRuleSafetyChecks()
        try merchantRuleMigrationChecks()
        try categorySuggestionChecks()
        try categorySuggestionSafetyChecks()
        try cardPaymentReceiptChecks()
        try cardPaymentDuplicateChecks()
        try aggregateChecks()
        try attributedBodyChecks()
        try sqliteChecks()
        try importWindowChecks()
        try refreshImportChecks()
        try demoFixtureChecks()
        try privateReviewChecks()
        try persistenceChecks()
        try deletionUndoChecks()
        try sourceRetrievalChecks()
        try categoryMigrationChecks()
        try categoryPersistenceChecks()
        try incomeCategoryChecks()
        try reconciliationChecks()
        try futureDebitNoticeChecks()
        try reconciliationAliasAndRollbackChecks()
        try monthlySummaryChecks()
        try monthlySummaryPersistenceChecks()
        try recurringPaymentChecks()
        try categorizationNavigationChecks()
        try credCardPaymentChecks()
        try reviewDiagnosticsChecks()
        try reviewSourceDiagnosticsChecks()
        try recipientReviewChecks()
        try recipientMiscellaneousChecks()
        try recipientSafetyChecks()
        try recipientMigrationChecks()
        print("Synthetic checks passed: parser, private review, read-only import/source retrieval, SQLite persistence, duplicate handling, corrections, deletions with session Undo, atomic rollback, category migration/persistence, safe parser refresh, local merchant suggestions, saved merchant category rules, reviewed category batches, automatic catalog pipeline, monthly spending/list reconciliation, explicit Income / Salary, recurring payment categories, local Needs Review diagnostics and recipient payment-type learning.")
    }
}

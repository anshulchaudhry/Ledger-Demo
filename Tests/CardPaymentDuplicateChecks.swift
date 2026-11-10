import Foundation

func cardPaymentDuplicateChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-card-link-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let received = Importer.start.addingTimeInterval(3600)
    let funding = message("JD-IDFCFB", "Your A/c XX0002 debited by Rs. 428.27 on 30/07/26; CRED credited. RRN TESTLINK01. Available balance Rs. 700.00.", "link-funding", received)
    func axis(_ id: String, amount: String = "428.27", seconds: TimeInterval) -> Message {
        message("AX-AXISBK", "Payment of INR \(amount) has been received towards your Axis Bank Credit Card XX0001 on 30-07-26 - Axis Bank",
                id, received.addingTimeInterval(seconds))
    }
    let issuer = axis("link-issuer", seconds: 55)
    let tooLate = axis("link-late", seconds: 601)
    let otherAmount = axis("link-amount", amount: "428.28", seconds: 55)
    let ordinaryCardDebit = message("VM-ICICIB", "INR 428.27 debited for credit card bill payment. Ref TESTLINK04.", "link-other-bank", received)
    let notice = message("AX-AXISBK", "Axis Bank Credit Card XX0001 amount due INR 428.27.", "link-notice", received)
    let input = [funding, issuer, tooLate, otherAmount, ordinaryCardDebit, notice]

    do {
        let store = try TransactionStore(url: url)
        try check(try store.ingest(input).inserted == 5, "card payment candidates stay separate until confirmed")
    }
    try withSyntheticSQL(url.path) { database in
        try testSQL(database, "DROP TABLE card_payment_links")
        try testSQL(database, "DROP TABLE import_scans")
        try testSQL(database, "PRAGMA user_version=5")
    }

    let store = try TransactionStore(url: url)
    let suggestions = try store.cardPaymentDuplicates(messages: input)
    try check(suggestions.count == 1 && suggestions[0].secondsApart == 55, "only an exact amount and complementary receipt within the window is suggested after migration")
    let initial = suggestions[0]
    var corrected = initial.issuer.record
    corrected.category = .billsUtilities
    corrected.merchant = "Fictional corrected card label"
    try store.save(corrected)
    do { try store.linkCardPayment(initial, keeping: initial.preferredRecordID); throw CheckFailure.failed("stale link preview should fail") }
    catch StoreError.staleSuggestions { }

    let before = try store.load()
    let pair = try store.cardPaymentDuplicates(messages: input)[0]
    try check(pair.preferredRecordID == corrected.id, "edited row is preferred in the preview")
    let month = LedgerMonth(containing: pair.funding.record.date)
    let previousTotal = try MonthlySummary(month: month, records: before).total(.cardPayments)
    try withSyntheticSQL(url.path) { database in
        try testSQL(database, "CREATE TRIGGER fail_card_link BEFORE INSERT ON card_payment_links BEGIN SELECT RAISE(ABORT,'fictional failure'); END")
    }
    do { try store.linkCardPayment(pair, keeping: corrected.id); throw CheckFailure.failed("failed link must be reported") }
    catch StoreError.operationFailed { }
    try check(try store.load() == before, "failed link leaves both saved rows visible")
    try withSyntheticSQL(url.path) { try testSQL($0, "DROP TRIGGER fail_card_link") }
    try store.linkCardPayment(pair, keeping: corrected.id)
    do { try store.linkCardPayment(pair, keeping: pair.funding.record.id); throw CheckFailure.failed("one record cannot be linked twice") }
    catch StoreError.staleSuggestions { }

    let reopened = try TransactionStore(url: url)
    let fundingID = pair.funding.record.id
    let receiptIDs = [ImportIdentity.source(issuer), ImportIdentity.source(funding)]
    let alias = message(funding.sender, funding.text, "funding-repeat", received.addingTimeInterval(70))
    let repeated = try reopened.ingest(input + [alias])
    try check(repeated.inserted == 0 && repeated.updated == 0, "linked rows and duplicate delivery remain stable on reimport")
    let linked = try reopened.load()
    try check(linked.count == 4 && linked.first { $0.id == corrected.id }?.linkedCardPaymentID == fundingID,
              "one chosen row remains visible across restart and reimport")
    try check(try reopened.linkedCardPaymentSources(id: corrected.id) == receiptIDs && reopened.sources(id: fundingID).count == 2,
              "both reviewed original identities and new aliases stay linked")
    let summary = try MonthlySummary(month: month, records: linked)
    try check(summary.total(.cardPayments).count == previousTotal.count - 1 &&
              summary.total(.cardPayments).amountPaise == previousTotal.amountPaise - 42827 && summary.total(.expenses).count == 0,
              "linked payment counts once in the card payment subtotal and stays outside spending")
    try check(try reopened.cardPaymentDuplicates(messages: input).isEmpty, "linked rows stay out of future suggestions")
    do { try reopened.delete(id: corrected.id); throw CheckFailure.failed("linked payment must be unlinked before deletion") }
    catch StoreError.linkedCardPayment { }
    var recategorized = linked.first { $0.id == corrected.id }!
    recategorized.type = .expense
    do { try reopened.save(recategorized); throw CheckFailure.failed("linked card payment cannot become an expense") }
    catch StoreError.linkedCardPayment { }

    try reopened.unlinkCardPayment(id: corrected.id, otherID: fundingID)
    try check(try reopened.load() == before, "unlink restores both rows and their exact saved edits")
    try reopened.delete(id: fundingID)
    _ = try reopened.ingest(input + [alias])
    try check(try reopened.cardPaymentDuplicates(messages: input).isEmpty && !reopened.load().contains { $0.id == fundingID },
              "deliberate deletion remains suppressed and cannot appear as a link suggestion")
    let bytes = try Data(contentsOf: url)
    try check(input.allSatisfy { bytes.range(of: Data($0.text.utf8)) == nil }, "payment link stores identities without retaining SMS bodies")
}

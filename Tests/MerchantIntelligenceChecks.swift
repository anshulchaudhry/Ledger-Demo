import Foundation

func axisIMPSPartyChecks() throws {
    let body = "INR 246.80 credited to A/c no. XX0004 at 18-10-26 10:42:17 IST\nRef: IMPS/P2A/123456789012/MIRA SEN\nFor any details, call 1800000000 - Axis Bank"
    let source = message("AX-AXISBK", body, "fictional-axis-imps")
    guard let parsed = Parser.parse(source) else { throw CheckFailure.failed("Axis IMPS transfer parses") }
    try check(parsed.merchant == "MIRA SEN" && parsed.direction == .credit && parsed.type == .transfer && !parsed.needsReview,
              "Axis IMPS sender comes from the end of the reference line")
    try check(parsed.amountPaise == 24680 && parsed.reference == nil, "name extraction preserves amount and duplicate identity policy")
    let singleLine = body.replacingOccurrences(of: "\n", with: " ")
    try check(Parser.parse(message("AX-AXISBK", singleLine))?.merchant == "MIRA SEN",
              "the name stops before the support footer even when the text is on one line")
    let variants = [
        body.replacingOccurrences(of: "/MIRA SEN", with: ""),
        body.replacingOccurrences(of: "MIRA SEN", with: "1234567890"),
        body.replacingOccurrences(of: "MIRA SEN", with: "mira@example.test"),
        body.replacingOccurrences(of: "P2A", with: "P2P"),
        body.replacingOccurrences(of: "credited to", with: "debited from"),
        body.replacingOccurrences(of: "credited to", with: "will be credited to"),
    ]
    try check(variants.allSatisfy { Parser.parse(message("AX-AXISBK", $0))?.merchant == nil },
              "unsupported references, outgoing transfers and contact details do not supply a sender name")
    try check(Parser.parse(message("VM-ICICIB", body))?.merchant == nil, "Axis sender extraction is bank-specific")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-axis-imps-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransactionStore(url: directory.appendingPathComponent("transactions.sqlite"))
    let editedSource = message(source.sender, body.replacingOccurrences(of: "246.80", with: "54.20"), "fictional-axis-imps-edited")
    let window = ImportWindow(from: source.receivedAt, through: source.receivedAt)!
    _ = try store.ingest([source, editedSource], window: window)
    let id = try store.load().first { $0.amountPaise == 24680 }!.id
    var edited = try store.load().first { $0.amountPaise == 5420 }!
    edited.merchant = "My saved sender label"
    try store.save(edited)
    try withSyntheticSQL(directory.appendingPathComponent("transactions.sqlite").path) { database in
        try testSQL(database, "UPDATE transactions SET merchant='Recipient not identified' WHERE id='\(id)'")
    }
    let result = try store.ingest([source, editedSource], window: window)
    let rows = try store.load()
    try check(result.updated == 1 && result.inserted == 0 && rows.first { $0.id == id }?.merchant == "MIRA SEN" &&
              rows.first { $0.id == edited.id }?.merchant == "My saved sender label" && rows.allSatisfy { !$0.isConfirmedExpense },
              "reimport fills the old name, preserves manual edits, and keeps incoming transfers outside spending")
}

func merchantIntelligenceChecks() throws {
    // Public brand names with entirely fictional amounts, dates, cards and phone numbers.
    let cardSMS = "INR 183.50 spent using ICICI Bank Card XX0001 on 12-Sep-26 on AMAZON PAY TEST. Avl Limit: INR 9,000. If not you, call 1800000000/SMS BLOCK 0001 to 9000000000."
    let source = message("VM-ICICIB", cardSMS, "fictional-merchant-card")
    guard let parsed = Parser.parse(source) else { throw CheckFailure.failed("card purchase template") }
    try check(parsed.merchant == "Amazon", "merchant comes from purchase clause rather than support phone")
    try check(parsed.type == .expense && parsed.direction == .debit && !parsed.needsReview, "explicit spent using card is expense")
    try check(parsed.amountPaise == 18350, "available limit does not replace purchase amount")
    try check(MerchantIntelligence.suggestedCategory(merchant: parsed.merchant!, type: parsed.type) == .shopping, "retailer category suggestion")
    let variations: [(String, String)] = [
        ("INR 15 spent using Axis Bank Card XX0002 on 12/09/26 at 14:20:30 on WILLOW GOODS. Available balance INR 500.", "WILLOW GOODS"),
        ("INR 15 spent using ICICI Bank Card XX0002 on GREEN GROCERY. Avl Limit INR 500.", "GREEN GROCERY"),
        ("INR 15 spent at Élan Café using card XX0002 on 12/09/26. If not you, call 1800000000.", "Élan Café"),
        ("INR 15 spent at 7CORNER on 12/09/26.", "7CORNER"),
        ("INR 15 spent using Your ICICI Bank Credit Card XX0002 on 12-Sep-26 on FICTIONAL RETAIL.", "FICTIONAL RETAIL"),
    ]
    for (text, expected) in variations {
        try check(Parser.parse(message("AX-AXISBK", text))?.merchant == expected, "merchant template and unicode regression")
    }
    try check(Parser.parse(message("VM-ICICIB", "INR 15 debited from A/c XX0002. If not you, call 1800000000 or SMS BLOCK to 9000000000."))?.merchant == nil, "fraud phone is never merchant fallback")
    try check(MerchantIntelligence.extract(from: "INR 15 sent to 9000000000.") == nil, "numeric-only participant remains unidentified")
    try check(MerchantIntelligence.extract(from: "INR 15 debited. To 9000000000 or contact support.") == nil, "phone followed by prose is not a merchant")
    try check(MerchantIntelligence.extract(from: "INR 15 debited. Call 1800000000 to report misuse.") == nil, "support prose after call is excluded from merchant candidates")
    try check(MerchantIntelligence.canonicalName("AMAZONAS SERVICES") == "AMAZONAS SERVICES", "unrelated names do not match a retailer prefix")
    try check(MerchantIntelligence.canonicalName("AMZN MKTPLACE TEST") == "Amazon", "known retailer descriptor alias")
    try check(Parser.parse(message("AX-AXISBK", "INR 15 debited for credit card bill payment."))?.type == .cardPayment, "card bill remains distinct from purchase")
    try check(Parser.parse(message("VM-ICICIB", "INR 15 received from AMAZON PAY TEST."))?.type == .incomingPayment, "brand name never converts incoming payment into expense")
    for type in [TransactionType.uncertain, .transfer, .cardPayment, .incomingPayment, .refund] {
        try check(MerchantIntelligence.suggestedCategory(merchant: "Amazon", type: type) == nil, "purpose suggestions do not classify non-expenses")
    }
    try check(MerchantIntelligence.suggestedCategory(merchant: "Maple Cafe", type: .expense) == .foodDining, "word-boundary food suggestion")
    try check(MerchantIntelligence.suggestedCategory(merchant: "Cafeine Holdings", type: .expense) == nil, "substring does not trigger suggestion")
    try check(MerchantIntelligence.suggestedCategory(merchant: "UNFAMILIAR MERCHANT", type: .expense) == nil, "unknown purpose remains uncategorized")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-merchant-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let store = try TransactionStore(url: url)
    _ = try store.ingest([source])
    let id = try store.load()[0].id
    // Simulate a result saved by the older parser, with a fictional support number.
    try withSyntheticSQL(url.path) { database in
        try testSQL(database, "UPDATE transactions SET merchant='9000000000',type='uncertain',edited=0,category='groceries'")
    }
    try check(try store.ingest([source]).updated == 1, "reimport repairs stale merchant and transaction type")
    var row = try store.load()[0]
    try check(row.id == id && row.merchant == "Amazon" && row.type == .expense && row.category == .groceries,
              "repair preserves identity and saved category")
    row.merchant = "Fictional manual merchant"
    row.type = .uncertain
    row.category = .health
    try store.save(row)
    _ = try store.ingest([source])
    let saved = try store.load()[0]
    try check(saved.merchant == row.merchant && saved.type == .uncertain && saved.category == .health && saved.needsReview,
              "new intelligence preserves manual choices and unresolved review state")
    // A user can still request fresh suggestions from the original source for an edited row.
    try check(Parser.parse(source)?.merchant == "Amazon" && Parser.parse(source)?.type == .expense,
              "on-demand source supplies a proposal without overwriting manual fields")
}

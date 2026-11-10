import Foundation

func credCardPaymentChecks() throws {
    // Every amount, date, instrument, reference and source ID here is fictional.
    let body = "Your A/c XX0004 debited by Rs. 37.25 on 14/10/26; CRED credited. RRN TESTCRED001. Available balance Rs. 9,000.00. Team IDFC FIRST Bank"
    let first = message("JD-IDFCFB", body, "fictional-cred-first")
    let second = message("JD-IDFCFB", body.replacingOccurrences(of: "37.25", with: "48.50").replacingOccurrences(of: "TESTCRED001", with: "TESTCRED002"), "fictional-cred-second")
    guard let parsed = Parser.parse(first) else { throw CheckFailure.failed("fictional IDFC CRED bill payment parses") }
    try check(parsed.bank == .idfc && parsed.direction == .debit && parsed.type == .cardPayment && !parsed.needsReview,
              "confirmed own-account IDFC debit to exact CRED recipient is card payment")
    try check(parsed.amountPaise == 3725 && parsed.maskedInstrument == "XX0004" && parsed.reference == "TESTCRED001",
              "CRED classification retains extracted fields and ignores available balance")
    try check(parsed.merchant == "CRED" && parsed.dateFromSMS && TransactionRecord.calendar.component(.day, from: parsed.transactionAt) == 14,
              "CRED classification preserves recipient and SMS date")
    let summary = Importer.summarize([first, second])
    try check(summary.byTransactionType["cardPayment"] == 2 && summary.byDirection["credit"] == nil,
              "separate CRED bills remain money-out card payments rather than incoming money")
    try check(Parser.parse(message("JD-IDFCFB", body.replacingOccurrences(of: "CRED credited", with: "cred credited")))?.type == .cardPayment,
              "exact CRED recipient is case insensitive")
    for recipient in ["CRED CLUB", "CREDITOR", "FICTIONAL PERSON", "CRED Membership"] {
        let alternative = body.replacingOccurrences(of: "CRED credited", with: "\(recipient) credited")
        try check(Parser.parse(message("JD-IDFCFB", alternative))?.type == .uncertain,
                  "related name or unrelated recipient never implies a credit card bill")
    }
    for status in ["Payment failed.", "Payment declined.", "Payment pending.", "Payment reversed.", "Refund initiated.", "Payment scheduled.", "Payment will be completed later.", "Payment has not been completed."] {
        try check(Parser.parse(message("JD-IDFCFB", body + " " + status))?.type != .cardPayment,
                  "uncompleted failed or reversal wording cannot establish a completed CRED bill payment")
    }
    for debit in ["will be debited", "not debited", "has not been debited"] {
        try check(Parser.parse(message("JD-IDFCFB", body.replacingOccurrences(of: "debited by", with: "\(debit) by")))?.type != .cardPayment,
                  "future and negated own-account debit cannot become CRED bill payment")
    }
    try check(Parser.parse(message("AX-AXISBK", body))?.type == .uncertain,
              "IDFC confirmation does not broaden another bank's unknown template")
    try check(Parser.parse(message("JD-IDFCFB", "Rs. 12 debited to CRED. Ref FICTIONALCRED11"))?.type == .uncertain,
              "generic CRED debit remains unresolved without the confirmed template")
    try check(Parser.parse(message("JD-IDFCFB", "Rs. 12 spent at CRED on 14/10/26. Ref FICTIONALCRED12"))?.type == .expense,
              "CRED brand alone cannot reclassify a purchase")
    try check(Parser.parse(message("JD-IDFCFB", body + " NEFT transfer."))?.type == .transfer,
              "explicit transfer classification stays intact")
    try check(Parser.parse(message("JD-IDFCFB", body + " Purchase at FICTIONAL SHOP."))?.type == .expense,
              "new template rule does not override explicit expense evidence")
    try check(Parser.parse(message("JD-IDFCFB", "Rs. 12 received from CRED on 14/10/26. Ref FICTIONALCRED13"))?.type == .incomingPayment,
              "incoming CRED payment is not a card bill")
    try check(Parser.parse(message("JD-IDFCFB", "Rs. 12 refunded from CRED on 14/10/26. Ref FICTIONALCRED14"))?.type == .refund,
              "CRED refund remains a refund")
    try check(Parser.parse(message("JD-IDFCFB", "Credit card payment of Rs. 12 is due. CRED reminder. Ignore if paid.")) == nil,
              "CRED bill reminder does not create a transaction")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-cred-payment-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let alias = message("JD-IDFCFB", body, "fictional-cred-redelivery")
    let expense = message("AX-AXISBK", "INR 10.01 spent at FICTIONAL CAFE on 14/10/26. Ref TESTCREDEXPENSE", "fictional-cred-expense")
    var firstID = ""
    var secondID = ""
    do {
        let store = try TransactionStore(url: url)
        try check(try store.ingest([first, second, alias, expense]).inserted == 3,
                  "distinct CRED bills are retained and a repeated delivery deduplicates")
        let rows = try store.load()
        firstID = rows.first { $0.amountPaise == 3725 }!.id
        secondID = rows.first { $0.amountPaise == 4850 }!.id
        try check(try store.sources(id: firstID).count == 2, "CRED redelivery keeps both original-source aliases")
        let month = LedgerMonth(containing: parsed.transactionAt)
        let fresh = try MonthlySummary(month: month, records: rows)
        try check(fresh.total(.expenses).amountPaise == 1001 && fresh.total(.cardPayments).amountPaise == 8575 && fresh.total(.cardPayments).count == 2,
                  "CRED bills are separate from confirmed monthly expenses without double-counting")
        let billList = rows.filter(MonthlyTransactionFilter(month: month, bucket: .cardPayments).includes)
        try check(Set(billList.map(\.id)) == [firstID, secondID], "monthly card-payment list contains both exact CRED bills")
        // Simulate prior unedited parser results; the store still has no raw SMS.
        try withSyntheticSQL(url.path) { database in
            try testSQL(database, "UPDATE transactions SET type='expense',category='groceries',edited=0 WHERE merchant='CRED'")
        }
        try check(try store.ingest([first, second, alias]).updated == 2, "reimport repairs old untouched CRED classifications")
        let refreshed = try store.load()
        try check(refreshed.filter { $0.merchant == "CRED" }.allSatisfy { $0.type == .cardPayment && $0.category == .groceries && !$0.isConfirmedExpense },
                  "parser refresh retains assigned purpose but excludes CRED bills from spending")
        try check(try MonthlySummary(month: month, records: refreshed).total(.expenses).amountPaise == 1001,
                  "old assigned category cannot keep a repaired card payment in spending totals")
        var manual = refreshed.first { $0.id == secondID }!
        manual.type = .transfer
        manual.merchant = "Fictional manual CRED correction"
        try store.save(manual)
        try store.delete(id: firstID)
    }
    let reopened = try TransactionStore(url: url)
    _ = try reopened.ingest([first, second, alias, expense])
    let saved = try reopened.load()
    try check(saved.count == 2 && !saved.contains { $0.id == firstID }, "CRED deletion survives restart and reimport")
    try check(saved.first { $0.id == secondID }?.type == .transfer && saved.first { $0.id == secondID }?.merchant == "Fictional manual CRED correction",
              "CRED parser change preserves manual corrections")
    try check(try Data(contentsOf: url).range(of: Data(body.utf8)) == nil, "CRED rule stores no full SMS")
}

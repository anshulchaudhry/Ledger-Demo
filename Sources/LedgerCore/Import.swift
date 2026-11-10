import Foundation
import SQLite3
import CryptoKit

package enum Bank: String, CaseIterable, Codable, Sendable {
    case axis = "Axis"
    case icici = "ICICI"
    case idfc = "IDFC FIRST"

    package static func from(sender: String) -> Bank? {
        let id = sender.uppercased()
        if id.contains("AXIS") { return .axis }
        if id.contains("ICICI") { return .icici }
        if id.contains("IDFC") { return .idfc }
        return nil
    }
}

package enum Direction: String, CaseIterable, Codable, Sendable {
    case debit, credit, uncertain
}

package enum TransactionType: String, CaseIterable, Codable, Sendable {
    case expense, transfer, cardPayment, refund, incomingPayment, uncertain
}

package struct Message: Sendable {
    package let guid: String
    package let sender: String
    package let text: String
    package let receivedAt: Date
    package let service: String
    package let isFromMe: Bool
    package let recoveredFromAttributedBody: Bool
    package let hadUndecodedAttributedBody: Bool

    package init(guid: String, sender: String, text: String, receivedAt: Date,
         service: String, isFromMe: Bool, recoveredFromAttributedBody: Bool = false,
         hadUndecodedAttributedBody: Bool = false) {
        self.guid = guid
        self.sender = sender
        self.text = text
        self.receivedAt = receivedAt
        self.service = service
        self.isFromMe = isFromMe
        self.recoveredFromAttributedBody = recoveredFromAttributedBody
        self.hadUndecodedAttributedBody = hadUndecodedAttributedBody
    }
}

package struct Transaction {
    package let bank: Bank
    package let direction: Direction
    package let amountPaise: Int64
    package let merchant: String?
    package let maskedInstrument: String?
    package let reference: String?
    package let transactionAt: Date
    package let dateFromSMS: Bool
    package let receivedAt: Date
    package let resolvedIDFCDualVerbDebit: Bool
    package let type: TransactionType

    package var needsReview: Bool { direction == .uncertain || type == .uncertain }
}

package enum Parser {
    private static let amountPattern = #"(?:\bINR\b|\bRS\.?|₹)\s*([0-9,]+(?:\.[0-9]{1,2})?)"#
    private static let debitPattern = #"\b(debited|spent|paid|sent|withdrawn)\b"#
    private static let creditPattern = #"\b(credited|received|refunded)\b"#
    private static let futureDebitPattern = #"\bwill\s+(?:not\s+)?be\s+debited\b"#

    // These fixed labels are the only diagnostics exposed by the CLI.
    package static func rejectionReason(_ message: Message) -> String {
        if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "missingText" }
        if isFutureDebitNotice(message.text) { return "futureDebitNotice" }
        if isCardBillReminder(message.text) { return "cardBillReminder" }
        if Bank.from(sender: message.sender) == .axis && isUnconfirmedAxisCardPayment(message.text) { return "unconfirmedCardPayment" }
        guard let amount = firstCapture(in: message.text, pattern: amountPattern) else { return "noRupeeAmount" }
        guard parsePaise(amount) != nil else { return "invalidAmount" }
        if !hasWord(message.text, debitPattern) && !hasWord(message.text, creditPattern) {
            return "noDirectionVerb"
        }
        return "other"
    }

    // Only affirmative nontransaction rules qualify for exclusion of a stale,
    // untouched import. A parse failure by itself is not evidence of removal.
    package static func isKnownNonTransaction(_ message: Message) -> Bool {
        isFutureDebitNotice(message.text) || isCardBillReminder(message.text) ||
            (Bank.from(sender: message.sender) == .axis && isUnconfirmedAxisCardPayment(message.text))
    }

    package static func uncertaintyVerbPair(_ text: String) -> String {
        func firstWord(_ pattern: String) -> String {
            guard let match = firstCapture(in: text, pattern: pattern) else { return "unknown" }
            return match.lowercased()
        }
        return firstWord(debitPattern) + "+" + firstWord(creditPattern)
    }

    package static func parse(_ message: Message) -> Transaction? {
        guard !message.isFromMe,
              message.service.uppercased() == "SMS",
              let bank = Bank.from(sender: message.sender),
              !isFutureDebitNotice(message.text),
              !isCardBillReminder(message.text),
              !(bank == .axis && isUnconfirmedAxisCardPayment(message.text)),
              let amount = firstCapture(in: message.text, pattern: amountPattern),
              let paise = parsePaise(amount) else { return nil }

        let cardPaymentReceipt = bank == .axis && isAxisCardPaymentReceipt(message.text)
        let debit = hasWord(message.text, debitPattern)
        let credit = hasWord(message.text, creditPattern)
        guard debit || credit else { return nil }
        // This specific IDFC wording names the user's account as debited and a
        // separate recipient as credited. Other dual-verb wording stays uncertain.
        let idfcRecipient = bank == .idfc ? firstCapture(
            in: message.text,
            pattern: #";\s*([A-Za-z][A-Za-z .'-]{1,60}?)\s+credited\b"#
        ) : nil
        let ownAccountDebited = hasWord(
            message.text,
            #"\byour\s+(?:a/c|account|acct)\s+(?:[Xx*]{2,}\d{2,6}\s+)?(?:has\s+been\s+)?debited\b"#
        )
        let ownAccountCredited = hasWord(
            message.text,
            #"\byour\s+(?:a/c|account|acct)\s+(?:[Xx*]{2,}\d{2,6}\s+)?(?:has\s+been\s+)?credited\b"#
        )
        let resolvedIDFCDualVerbDebit = bank == .idfc && debit && credit &&
            ownAccountDebited && !ownAccountCredited && idfcRecipient != nil
        let direction: Direction = (cardPaymentReceipt || resolvedIDFCDualVerbDebit) ? .debit :
            (debit == credit ? .uncertain : (debit ? .debit : .credit))

        let masked = firstCapture(
            in: message.text,
            pattern: #"\b(?:a/c|acct|account|card)\s*(?:no\.?|ending)?\s*([Xx*]{2,}\d{2,4})\b"#
        )
        let reference = firstCapture(
            in: message.text,
            pattern: #"\b(?:UPI\s+Ref(?:\s+No)?|Ref(?:erence)?(?:\s+(?:No|ID))?|Txn(?:\s+ID)?|RRN)\s*[:#-]?\s*([A-Za-z0-9]{6,})\b"#
        )?.uppercased()
        let smsDate = transactionDate(in: message.text)
        let parsedType = transactionType(in: message.text, direction: direction)
        // User-confirmed IDFC own-account debit / exact CRED recipient template.
        // Do not infer bill payment from a CRED mention, purchase, transfer,
        // incoming payment or uncompleted/reversed notice.
        let idfcCredBillPayment = resolvedIDFCDualVerbDebit && parsedType == .uncertain &&
            idfcRecipient?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "CRED" &&
            !hasWord(message.text, #"\b(?:refund(?:ed)?|reversal|reversed|failed|declined|cancelled|canceled|pending|scheduled|initiated|will\s+be|(?:has\s+not\s+been|not)\s+(?:debited|credited|completed|successful))\b"#)
        let type: TransactionType = cardPaymentReceipt || idfcCredBillPayment ? .cardPayment : parsedType
        let axisSender = bank == .axis && direction == .credit && type == .transfer
            ? axisIMPSSender(in: message.text) : nil
        let merchant = axisSender ?? MerchantIntelligence.extract(from: message.text) ?? idfcRecipient.map(MerchantIntelligence.canonicalName)

        return Transaction(bank: bank, direction: direction, amountPaise: paise,
                           merchant: cardPaymentReceipt ? "Credit card payment" : merchant, maskedInstrument: masked,
                           reference: reference, transactionAt: smsDate ?? message.receivedAt,
                           dateFromSMS: smsDate != nil, receivedAt: message.receivedAt,
                           resolvedIDFCDualVerbDebit: resolvedIDFCDualVerbDebit, type: type)
    }

    // Axis puts the sender's display name after the numeric IMPS/P2A reference.
    private static func axisIMPSSender(in text: String) -> String? {
        let credit = #"^\s*"# + amountPattern + #"\s+(?:has\s+been\s+)?credited\s+to\s+a/c\s+(?:no\.?\s*)?[Xx*]{2,}\d{2,6}\b"#
        guard hasWord(text, credit) else { return nil }
        let reference = #"\bref(?:erence)?\h*:\h*IMPS\h*/\h*P2A\h*/\h*[0-9]{12}\h*/\h*"#
        let name = #"(\p{L}[\p{L}\p{M} .’'-]{0,59}?)(?=\h*(?:\R|$|\.?\h+for\h+any\h+details\b))"#
        return firstCapture(in: text, pattern: reference + name)?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // This specific issuer receipt confirms settlement of the user's card bill.
    // "Received" is from the bank's perspective: represent it as a card payment
    // / money out, never incoming money or a new purchase expense.
    private static func axisCardReceiptPattern(status: String) -> String {
        #"^\s*payment\s+of\s+(?:INR\b|RS\.?|₹)\s*[0-9,]+(?:\.[0-9]{1,2})?\s+"# + status +
        #"\s+towards\s+your\s+Axis\s+Bank\s+credit\s+card\s+(?:no\.?\s*)?[Xx*]{2,}\d{2,4}\b"#
    }

    package static func isAxisCardPaymentReceipt(_ text: String) -> Bool {
        guard !hasWord(text, #"\b(?:refund(?:ed)?|reversal|reversed|failed|declined|cancelled|canceled)\b"#) else { return false }
        return hasWord(text, axisCardReceiptPattern(status: #"(?:has\s+been\s+)?received"#))
    }

    private static func isUnconfirmedAxisCardPayment(_ text: String) -> Bool {
        if hasWord(text, axisCardReceiptPattern(status: #"(?:has\s+not\s+been|will\s+be)\s+received"#)) { return true }
        return hasWord(text, #"\b(?:failed|declined|cancelled|canceled)\b"#) &&
            hasWord(text, axisCardReceiptPattern(status: #"(?:has\s+been\s+)?received"#))
    }

    private static func isFutureDebitNotice(_ text: String) -> Bool {
        guard hasWord(text, futureDebitPattern) else { return false }
        // A receipt can also mention the next scheduled debit. Look for a
        // separate payment statement before excluding the whole message.
        let remaining = text.replacingOccurrences(of: futureDebitPattern, with: "", options: [.regularExpression, .caseInsensitive])
        return !hasWord(remaining, debitPattern) && !hasWord(remaining, creditPattern)
    }

    // Conditional "paid" wording and delivery of the statement are not
    // evidence that money moved.
    private static func isCardBillReminder(_ text: String) -> Bool {
        guard hasWord(text, #"\bcredit\s+card\b"#),
              hasWord(text, #"\b(?:is\s+due|minimum\s+(?:amount\s+)?due|payment\s+due|amount\s+due|total\s+(?:amount\s+)?due)\b"#) else { return false }
        let paymentWording = text.replacingOccurrences(
            of: #"\b(?:(?:ignore|disregard)\s+if\s+(?:already\s+)?paid|statement\s+(?:(?:is|was|has\s+been)\s+)?sent\s+to)\b"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        // Keep genuine posted-payment/debit confirmations that also mention
        // a remaining amount due. Broader wording remains conservative.
        return !hasWord(paymentWording, debitPattern) && !hasWord(paymentWording, creditPattern)
    }

    private static func transactionType(in text: String, direction: Direction) -> TransactionType {
        guard direction != .uncertain else { return .uncertain }
        if direction == .credit && hasWord(text, #"\b(refund(?:ed)?|reversal|reversed)\b"#) { return .refund }
        if direction == .debit && hasWord(text, #"\b(?:credit\s+card\s+(?:bill|payment)|payment\s+(?:towards|for)\s+(?:your\s+)?credit\s+card|card\s+bill\s+paid)\b"#) {
            return .cardPayment
        }
        if hasWord(text, #"\b(?:self[ -]?transfer|funds?\s+transfer|NEFT|IMPS|RTGS)\b"#) { return .transfer }
        if direction == .credit { return .incomingPayment }
        let spentUsingCard = hasWord(text, #"\bspent\s+(?:using|on)\s+(?:[A-Za-z]+\s+){0,5}card\s+(?:no\.?\s*)?[Xx*]{2,}\d{2,4}\b"#)
        if spentUsingCard || hasWord(text, #"\b(?:purchase(?:d)?|POS|spent\s+(?:at|on)|paid\s+at)\b"#) { return .expense }
        return .uncertain
    }

    private static func hasWord(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func firstCapture(in value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private static func parsePaise(_ value: String) -> Int64? {
        let parts = value.replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false)
        guard let rupees = Int64(parts[0]), rupees >= 0,
              rupees <= (Int64.max - 99) / 100 else { return nil }
        let fractional = parts.count == 2 ? String(parts[1]).padding(toLength: 2, withPad: "0", startingAt: 0) : "00"
        guard let paise = Int64(fractional) else { return nil }
        let total = rupees * 100 + paise
        return total > 0 ? total : nil
    }

    private static func transactionDate(in text: String) -> Date? {
        let pattern = #"\bon\s+(\d{1,2}[-/](?:[A-Za-z]{3,9}|\d{1,2})[-/]\d{2,4})(?:\s+(?:at\s+)?(\d{1,2}:\d{2}(?::\d{2})?))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let dateRange = Range(match.range(at: 1), in: text) else { return nil }
        let dateText = String(text[dateRange])
        let timeText = Range(match.range(at: 2), in: text).map { String(text[$0]) }
        let formats = ["dd-MMM-yy", "dd-MMM-yyyy", "dd/MM/yy", "dd/MM/yyyy", "dd-MM-yy", "dd-MM-yyyy"]
        for dateFormat in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = Importer.timeZone
            formatter.isLenient = false
            let timeFormat = timeText?.count == 8 ? "HH:mm:ss" : "HH:mm"
            formatter.dateFormat = dateFormat + (timeText == nil ? "" : " 'at' " + timeFormat)
            let input = dateText + (timeText.map { " at " + $0 } ?? "")
            if let date = formatter.date(from: input) { return date }
        }
        return nil
    }
}

package struct Summary: Codable {
    package let window: String
    package var candidateMessages = 0
    package var parsedTransactions = 0
    package var duplicateTransactions = 0
    package var needsReview = 0
    package var unparsedCandidates = 0
    package var datesFromSMS = 0
    package var recoveredAttributedBodies = 0
    package var recoveredAttributedBodiesByBank: [String: Int] = [:]
    package var undecodedAttributedBodies = 0
    package var undecodedAttributedBodiesByBank: [String: Int] = [:]
    package var resolvedIDFCDualVerbDebits = 0
    package var byBank: [String: Int] = [:]
    package var byDirection: [String: Int] = [:]
    package var byTransactionType: [String: Int] = [:]
    package var unparsedByReason: [String: Int] = [:]
    package var unparsedByBank: [String: Int] = [:]
    package var missingTextByBank: [String: Int] = [:]
    package var uncertainByBank: [String: Int] = [:]
    package var uncertainTypeByBank: [String: Int] = [:]
    package var uncertainVerbPairs: [String: Int] = [:]
}

package enum Importer {
    package static let timeZone = TimeZone(identifier: "Asia/Kolkata")!
    package static let start = day(2026, 7, 30)
    package static let endExclusive = day(2026, 10, 31)

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    package static func summarize(_ messages: [Message]) -> Summary {
        var result = Summary(window: "2026-07-30 through 2026-10-30 (Asia/Kolkata)")
        var seenGUIDs = Set<String>()
        var seenTransactions = Set<String>()

        for message in messages {
            guard message.receivedAt >= start, message.receivedAt < endExclusive,
                  !message.isFromMe, message.service.uppercased() == "SMS",
                  let bank = Bank.from(sender: message.sender) else { continue }
            result.candidateMessages += 1
            if message.recoveredFromAttributedBody {
                result.recoveredAttributedBodies += 1
                result.recoveredAttributedBodiesByBank[bank.rawValue, default: 0] += 1
            }
            if message.hadUndecodedAttributedBody {
                result.undecodedAttributedBodies += 1
                result.undecodedAttributedBodiesByBank[bank.rawValue, default: 0] += 1
            }
            guard let transaction = Parser.parse(message) else {
                result.unparsedCandidates += 1
                let reason = Parser.rejectionReason(message)
                result.unparsedByReason[reason, default: 0] += 1
                result.unparsedByBank[bank.rawValue, default: 0] += 1
                if reason == "missingText" { result.missingTextByBank[bank.rawValue, default: 0] += 1 }
                continue
            }

            // References can identify a transaction even when its SMS is delivered twice.
            // Without one, require the same sender, minute and exact normalized text.
            let key = ImportIdentity.duplicate(message, transaction: transaction)
            if (!message.guid.isEmpty && !seenGUIDs.insert(message.guid).inserted) || !seenTransactions.insert(key).inserted {
                result.duplicateTransactions += 1
                continue
            }
            result.parsedTransactions += 1
            if transaction.resolvedIDFCDualVerbDebit { result.resolvedIDFCDualVerbDebits += 1 }
            if transaction.dateFromSMS { result.datesFromSMS += 1 }
            result.byBank[transaction.bank.rawValue, default: 0] += 1
            result.byDirection[transaction.direction.rawValue, default: 0] += 1
            result.byTransactionType[transaction.type.rawValue, default: 0] += 1
            if transaction.needsReview { result.needsReview += 1 }
            if transaction.type == .uncertain {
                result.uncertainTypeByBank[transaction.bank.rawValue, default: 0] += 1
            }
            if transaction.direction == .uncertain {
                result.uncertainByBank[transaction.bank.rawValue, default: 0] += 1
                result.uncertainVerbPairs[Parser.uncertaintyVerbPair(message.text), default: 0] += 1
            }
        }
        return result
    }
}

package enum DatabaseError: Error {
    case unavailable
    case unsupportedSchema
    case queryFailed
}

// Reads only the first NSString payload in Apple's typedstream body. The framing
// approach follows openclaw/imsg's MIT-licensed TypedStreamParser; malformed or
// unrecognised archives are left unparsed rather than guessed from binary bytes.
package enum AttributedBodyDecoder {
    package static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xff, 0xfe]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        guard bytes.count >= 16, bytes[0] == 4, bytes[1] == 11 else { return nil }
        let signature = bytes[2..<13]
        let littleEndian = signature.elementsEqual("streamtyped".utf8)
        guard littleEndian || signature.elementsEqual("typedstream".utf8) else { return nil }

        for index in 13..<(bytes.count - 2) where bytes[index] == 0x01 && bytes[index + 1] == 0x2b {
            let lengthIndex = index + 2
            let marker = bytes[lengthIndex]
            var start = lengthIndex + 1
            let length: Int
            if marker == 0x81 || marker == 0x82 {
                let width = marker == 0x81 ? 2 : 4
                guard width <= bytes.count - start else { return nil }
                var value = 0
                for offset in 0..<width {
                    let shift = (littleEndian ? offset : width - 1 - offset) * 8
                    value |= Int(bytes[start + offset]) << shift
                }
                length = value
                start += width
            } else {
                guard marker < 0x80 else { return nil }
                length = Int(marker)
            }
            guard length <= bytes.count - start else { return nil }
            return String(bytes: bytes[start..<(start + length)], encoding: .utf8)
        }
        return nil
    }
}

package enum MessagesReader {
    package static func read(path: String, window: ImportWindow = .legacy) throws -> [Message] {
        try query(path: path, guid: nil, window: window)
    }

    // The identity is immutable even after the user edits a transaction.
    package static func original(path: String, source: SourceIdentity) throws -> String? {
        try originalMessage(path: path, source: source)?.text
    }

    package static func originalMessage(path: String, source: SourceIdentity, window: ImportWindow = .legacy) throws -> Message? {
        let matches = try query(path: path, guid: source.guid, window: window)
            .filter { ImportIdentity.source($0).key == source.key }
        return matches.first(where: { !$0.text.isEmpty })
    }

    private static func query(path: String, guid: String?, window: ImportWindow) throws -> [Message] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { sqlite3_close(database); throw DatabaseError.unavailable }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }

        // Filter by date, SMS service and bank sender in SQLite before reading text.
        // Apple stores dates as seconds or nanoseconds since 2001 in observed schemas.
        let query = """
        SELECT m.guid, h.id, m.text, m.attributedBody, m.date, m.service, m.is_from_me
        FROM message AS m JOIN handle AS h ON h.ROWID = m.handle_id
        WHERE m.is_from_me = 0 AND UPPER(m.service) = 'SMS'
          AND (LOWER(h.id) LIKE '%axis%' OR LOWER(h.id) LIKE '%icici%' OR LOWER(h.id) LIKE '%idfc%')
          AND (CASE WHEN m.date > 100000000000000 THEN m.date / 1000000000.0 ELSE m.date END) >= ?
          AND (CASE WHEN m.date > 100000000000000 THEN m.date / 1000000000.0 ELSE m.date END) < ?
          AND (? IS NULL OR m.guid = ?)
        ORDER BY m.date, m.ROWID
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { sqlite3_finalize(statement); throw DatabaseError.unsupportedSchema }
        defer { sqlite3_finalize(statement) }
        let appleEpoch = Date(timeIntervalSince1970: 978307200)
        sqlite3_bind_double(statement, 1, window.start.timeIntervalSince(appleEpoch))
        sqlite3_bind_double(statement, 2, window.endExclusive.timeIntervalSince(appleEpoch))
        if let guid {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 3, guid, -1, transient)
            sqlite3_bind_text(statement, 4, guid, -1, transient)
        }
        var messages: [Message] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return messages }
            guard status == SQLITE_ROW else { throw DatabaseError.queryFailed }
            guard let sender = sqlite3_column_text(statement, 1) else { continue }
            let plainText = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            var body = plainText
            var recovered = false
            var undecoded = false
            if body.isEmpty, let blob = sqlite3_column_blob(statement, 3) {
                let size = Int(sqlite3_column_bytes(statement, 3))
                if size > 0 && size <= 65_536,
                   let decoded = AttributedBodyDecoder.decode(Data(bytes: blob, count: size)),
                   !decoded.isEmpty {
                    body = decoded
                    recovered = true
                } else if size > 0 {
                    undecoded = true
                }
            }
            let rawDate = sqlite3_column_double(statement, 4)
            let seconds = rawDate > 100000000000000 ? rawDate / 1_000_000_000 : rawDate
            messages.append(Message(
                guid: sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "",
                sender: String(cString: sender), text: body,
                receivedAt: appleEpoch.addingTimeInterval(seconds),
                service: sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? "",
                isFromMe: sqlite3_column_int(statement, 6) != 0,
                recoveredFromAttributedBody: recovered,
                hadUndecodedAttributedBody: undecoded
            ))
        }
    }
}

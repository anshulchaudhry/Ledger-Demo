#if canImport(LedgerCore)
import LedgerCore
#endif
import Foundation
import CryptoKit
import Darwin

enum ReviewStratum: String, Codable {
    case parsed, unparsed, dualVerb
}

struct ReviewItem {
    let id: String
    let bank: Bank
    let stratum: ReviewStratum
    let message: Message
    let transaction: Transaction?

    init?(message: Message) {
        guard message.receivedAt >= Importer.start,
              message.receivedAt < Importer.endExclusive,
              !message.isFromMe, message.service.uppercased() == "SMS",
              let bank = Bank.from(sender: message.sender) else { return nil }
        self.message = message
        self.bank = bank
        self.transaction = Parser.parse(message)
        if transaction == nil {
            self.stratum = .unparsed
        } else if message.text.range(of: #"\bdebited\b"#, options: [.regularExpression, .caseInsensitive]) != nil &&
                    message.text.range(of: #"\bcredited\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            self.stratum = .dualVerb
        } else {
            self.stratum = .parsed
        }
        let source = message.guid.isEmpty
            ? "\(message.sender)|\(message.receivedAt.timeIntervalSince1970)|\(message.text)"
            : message.guid
        self.id = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum ReviewSampler {
    static let target = 55
    static let quickPass = 10

    static func select(_ messages: [Message]) -> [ReviewItem] {
        let unique = Dictionary(messages.compactMap(ReviewItem.init).map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        let all = unique.values.sorted { $0.id < $1.id }
        var chosen: [ReviewItem] = []
        var ids = Set<String>()

        func add(_ items: [ReviewItem], count: Int) {
            var added = 0
            for item in items where chosen.count < ReviewSampler.target && added < count {
                if ids.insert(item.id).inserted {
                    chosen.append(item)
                    added += 1
                }
            }
        }

        func parsedPool(for bank: Bank) -> [ReviewItem] {
            let parsed = all.filter { $0.bank == bank && $0.stratum == .parsed }
            var diverse: [ReviewItem] = []
            for type in TransactionType.allCases {
                if let item = parsed.first(where: { $0.transaction?.type == type }) { diverse.append(item) }
            }
            return diverse + parsed
        }

        func unparsedPool(for bank: Bank) -> [ReviewItem] {
            let unparsed = all.filter { $0.bank == bank && $0.stratum == .unparsed }
            var varied: [ReviewItem] = []
            for reason in ["missingText", "noRupeeAmount", "noDirectionVerb", "invalidAmount"] {
                if let item = unparsed.first(where: { Parser.rejectionReason($0.message) == reason }) {
                    varied.append(item)
                }
            }
            return varied + unparsed
        }

        let dual = all.filter { $0.stratum == .dualVerb }.sorted { a, b in
            let aUncertain = a.transaction?.direction == .uncertain
            let bUncertain = b.transaction?.direction == .uncertain
            return aUncertain == bUncertain ? a.id < b.id : aUncertain
        }

        // First ten: two parsed and one unparsed per bank, plus the most
        // uncertain dual-verb message. Later plan entries remain optional.
        for bank in Bank.allCases {
            add(parsedPool(for: bank), count: 2)
            add(unparsedPool(for: bank), count: 1)
        }
        add(dual, count: 1)

        // Preserve the original 55-message stratification if the quick pass
        // shows that a broader audit is useful.
        for bank in Bank.allCases {
            let parsedCount = chosen.filter { $0.bank == bank && $0.stratum == .parsed }.count
            let unparsedCount = chosen.filter { $0.bank == bank && $0.stratum == .unparsed }.count
            add(parsedPool(for: bank), count: max(0, 10 - parsedCount))
            add(unparsedPool(for: bank), count: max(0, 5 - unparsedCount))
        }
        let dualCount = chosen.filter { $0.stratum == .dualVerb }.count
        add(dual, count: max(0, 10 - dualCount))
        add(all, count: target - chosen.count)
        return chosen
    }
}

struct ReviewPlanEntry: Codable {
    let id: String
    let bank: Bank
    let stratum: ReviewStratum
    let predictedType: TransactionType?
}

enum ReviewVerdict: String, Codable {
    case correct, incorrect, nonTransaction
}

enum ReviewErrorKind: String, CaseIterable, Codable {
    case amount, date, direction, merchant, bank, type, missedTransaction, other
}

struct ReviewDecision: Codable {
    let id: String
    let verdict: ReviewVerdict
    let errors: [ReviewErrorKind]
    let actualType: TransactionType?
}

struct ReviewState: Codable {
    let version: Int
    var plan: [ReviewPlanEntry]
    var decisions: [ReviewDecision]

    init(items: [ReviewItem]) {
        version = 1
        plan = items.map { ReviewPlanEntry(id: $0.id, bank: $0.bank,
                                           stratum: $0.stratum, predictedType: $0.transaction?.type) }
        decisions = []
    }
}

enum ReviewError: Error {
    case terminalRequired, noState, invalidState, noSamples
}

struct ReviewStore {
    let url: URL

    static var local: ReviewStore {
        ReviewStore(url: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local-review/milestone-001b.json"))
    }

    func load() throws -> ReviewState {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ReviewError.noState }
        let state = try JSONDecoder().decode(ReviewState.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw ReviewError.invalidState }
        return state
    }

    func loadOrCreate(items: [ReviewItem]) throws -> ReviewState {
        if FileManager.default.fileExists(atPath: url.path) {
            var state = try load()
            let oldEntries = Dictionary(state.plan.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let newIDs = items.map(\.id)
            if Set(newIDs) == Set(state.plan.map(\.id)),
               newIDs != state.plan.map(\.id) {
                // Reorder an existing 55-item plan for the 15-item checkpoint.
                // Keep every completed decision and its original prediction.
                state.plan = newIDs.compactMap { oldEntries[$0] }
                try save(state)
            }
            return state
        }
        guard !items.isEmpty else { throw ReviewError.noSamples }
        let state = ReviewState(items: items)
        try save(state)
        return state
    }

    func save(_ state: ReviewState) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
        _ = chmod(url.path, 0o600)
    }
}

struct ReviewReport: Codable {
    let samplingNote: String
    let selected: Int
    let reviewed: Int
    let checkpointTarget: Int
    let checkpointRemaining: Int
    let optionalExtendedRemaining: Int
    let quickCheckpointComplete: Bool
    let byStratum: [String: Int]
    let reviewedByBank: [String: Int]
    let verdicts: [String: Int]
    let outcomesByStratum: [String: Int]
    let errorTypes: [String: Int]
    let actualTransactionTypes: [String: Int]
    let typeCorrections: [String: Int]
    let parsedExactMatchPercent: Double?
    let sampledTransactionDetectionPercent: Double?

    init(state: ReviewState) {
        samplingNote = "The first checkpoint is 10 completed answers total, including earlier answers. Further review is optional. Percentages describe reviewed samples only, not the full inbox."
        selected = state.plan.count
        let validIDs = Set(state.plan.map(\.id))
        let decisions = Dictionary(state.decisions.filter { validIDs.contains($0.id) }
            .map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        reviewed = decisions.count
        checkpointTarget = min(ReviewSampler.quickPass, selected)
        checkpointRemaining = max(0, checkpointTarget - reviewed)
        optionalExtendedRemaining = max(0, selected - reviewed)
        quickCheckpointComplete = checkpointRemaining == 0
        var strata: [String: Int] = [:]
        var banks: [String: Int] = [:]
        var verdictCounts: [String: Int] = [:]
        var outcomes: [String: Int] = [:]
        var errors: [String: Int] = [:]
        var types: [String: Int] = [:]
        var corrections: [String: Int] = [:]
        var parsedReviewed = 0
        var parsedCorrect = 0
        var detectedTransactions = 0
        var missedTransactions = 0

        for entry in state.plan {
            strata[entry.stratum.rawValue, default: 0] += 1
            guard let decision = decisions[entry.id] else { continue }
            banks[entry.bank.rawValue, default: 0] += 1
            verdictCounts[decision.verdict.rawValue, default: 0] += 1
            outcomes["\(entry.stratum.rawValue).\(decision.verdict.rawValue)", default: 0] += 1
            for error in decision.errors { errors[error.rawValue, default: 0] += 1 }
            if let actual = decision.actualType { types[actual.rawValue, default: 0] += 1 }
            if entry.stratum != .unparsed {
                parsedReviewed += 1
                if decision.verdict == .correct { parsedCorrect += 1 }
                if decision.verdict != .nonTransaction { detectedTransactions += 1 }
            } else if decision.verdict == .incorrect {
                missedTransactions += 1
            }
            if let actual = decision.actualType,
               entry.predictedType != actual {
                let key = "\(entry.predictedType?.rawValue ?? "unparsed")->\(actual.rawValue)"
                corrections[key, default: 0] += 1
            }
        }
        byStratum = strata
        reviewedByBank = banks
        verdicts = verdictCounts
        outcomesByStratum = outcomes
        errorTypes = errors
        actualTransactionTypes = types
        typeCorrections = corrections
        parsedExactMatchPercent = parsedReviewed > 0
            ? (1000.0 * Double(parsedCorrect) / Double(parsedReviewed)).rounded() / 10.0 : nil
        let truthTransactions = detectedTransactions + missedTransactions
        sampledTransactionDetectionPercent = truthTransactions > 0
            ? (1000.0 * Double(detectedTransactions) / Double(truthTransactions)).rounded() / 10.0 : nil
    }
}

enum PrivateReview {
    private enum Action {
        case decision(ReviewDecision), skip, quit
    }

    static func run(databasePath: String, extended: Bool = false) throws -> ReviewReport {
        let environment = ProcessInfo.processInfo.environment
        let localTerminal = ["Apple_Terminal", "iTerm.app"].contains(environment["TERM_PROGRAM"] ?? "")
        guard localTerminal, environment["SSH_CONNECTION"] == nil,
              isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
              let tty = FileHandle(forWritingAtPath: "/dev/tty") else {
            throw ReviewError.terminalRequired
        }
        let items = ReviewSampler.select(try MessagesReader.read(path: databasePath))
        let store = ReviewStore.local
        var state = try store.loadOrCreate(items: items)
        let lookup = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let goal = extended ? state.plan.count : min(ReviewSampler.quickPass, state.plan.count)
        reviewLoop: for entry in state.plan {
            if state.decisions.count >= goal { break }
            if state.decisions.contains(where: { $0.id == entry.id }) { continue }
            guard let item = lookup[entry.id] else { continue }
            show(item, number: state.decisions.count + 1, total: goal, on: tty)
            switch askDecision(for: item, on: tty) {
            case .decision(let decision):
                state.decisions.append(decision)
                try store.save(state)
            case .skip:
                continue
            case .quit:
                break reviewLoop
            }
        }
        tty.write(Data("\u{001B}[2J\u{001B}[H\u{001B}[3JPrivate review paused or checkpoint complete. Aggregate report follows.\n".utf8))
        return ReviewReport(state: state)
    }

    static func report() throws -> ReviewReport {
        ReviewReport(state: try ReviewStore.local.load())
    }

    static func safeTerminalText(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            if scalar == "\n" || scalar == "\t" { return String(scalar) }
            return CharacterSet.controlCharacters.contains(scalar) ? "�" : String(scalar)
        }.joined()
    }

    private static func show(_ item: ReviewItem, number: Int, total: Int, on tty: FileHandle) {
        var lines = "\u{001B}[2J\u{001B}[H\u{001B}[3JLedger private review \(number)/\(total)\n"
        lines += "Bank: \(item.bank.rawValue) | Sample: \(item.stratum.rawValue)\n\n"
        lines += "SMS (local Terminal only):\n\(safeTerminalText(item.message.text))\n\n"
        if let transaction = item.transaction {
            let rupees = transaction.amountPaise / 100
            let paise = String(transaction.amountPaise % 100).leftPadded(to: 2)
            let amount = "₹\(rupees).\(paise)"
            lines += "Parsed: amount \(amount) | date \(format(transaction.transactionAt))"
            lines += transaction.dateFromSMS ? " (SMS date)\n" : " (receipt time fallback)\n"
            lines += "Direction: \(transaction.direction.rawValue) | Type: \(transaction.type.rawValue)"
            lines += transaction.needsReview ? " | Needs Review\n" : "\n"
            lines += "Merchant/recipient: \(transaction.merchant ?? "—") | Bank: \(transaction.bank.rawValue)\n"
        } else {
            lines += "Parsed: no transaction (\(Parser.rejectionReason(item.message)))\n"
        }
        if item.transaction == nil {
            lines += "\nMark i=missed transaction, n=non-transaction, s=skip, q=quit\n> "
        } else {
            lines += "\nMark c=all fields correct, i=incorrect, n=non-transaction, s=skip, q=quit\n> "
        }
        tty.write(Data(lines.utf8))
    }

    private static func askDecision(for item: ReviewItem, on tty: FileHandle) -> Action {
        while let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            switch input {
            case "q": return .quit
            case "s": return .skip
            case "c" where item.transaction != nil:
                return .decision(ReviewDecision(id: item.id, verdict: .correct, errors: [],
                                                actualType: item.transaction?.type))
            case "n":
                return .decision(ReviewDecision(id: item.id, verdict: .nonTransaction,
                                                errors: [], actualType: nil))
            case "i":
                if item.transaction == nil {
                    guard let type = askType(on: tty) else { return .quit }
                    return .decision(ReviewDecision(id: item.id, verdict: .incorrect,
                                                    errors: [.missedTransaction], actualType: type))
                }
                guard let errors = askErrors(on: tty), let type = askType(on: tty) else { return .quit }
                return .decision(ReviewDecision(id: item.id, verdict: .incorrect,
                                                errors: errors, actualType: type))
            default:
                tty.write(Data("Enter c, i, n, s or q: ".utf8))
            }
        }
        return .quit
    }

    private static func askErrors(on tty: FileHandle) -> [ReviewErrorKind]? {
        let choices: [ReviewErrorKind] = [.amount, .date, .direction, .merchant, .bank, .type, .other]
        tty.write(Data("Error fields (comma-separated numbers): 1 amount, 2 date, 3 direction, 4 merchant, 5 bank, 6 type, 7 other\n> ".utf8))
        while let input = readLine() {
            if input.lowercased() == "q" { return nil }
            let indices = input.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let unique = Array(Set(indices)).sorted()
            if !unique.isEmpty && unique.allSatisfy({ (1...7).contains($0) }) {
                return unique.map { choices[$0 - 1] }
            }
            tty.write(Data("Choose one or more numbers from 1 to 7, or q: ".utf8))
        }
        return nil
    }

    private static func askType(on tty: FileHandle) -> TransactionType? {
        let choices = TransactionType.allCases
        tty.write(Data("Actual type: 1 expense, 2 transfer, 3 card payment, 4 refund, 5 incoming payment, 6 uncertain\n> ".utf8))
        while let input = readLine() {
            if input.lowercased() == "q" { return nil }
            if let number = Int(input), (1...choices.count).contains(number) { return choices[number - 1] }
            tty.write(Data("Choose 1 to 6, or q: ".utf8))
        }
        return nil
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_IN")
        formatter.timeZone = Importer.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date) + " IST"
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        String(repeating: "0", count: max(0, width - count)) + self
    }
}

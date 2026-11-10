import Foundation

package struct CardPaymentDuplicate: Identifiable, Sendable {
    package struct ID: Hashable, Sendable {
        let funding: String
        let issuer: String
    }

    package struct Receipt: Sendable {
        package let record: TransactionRecord
        package let message: Message
        let source: SourceIdentity
    }

    package let funding: Receipt
    package let issuer: Receipt
    package var id: ID { ID(funding: funding.record.id, issuer: issuer.record.id) }
    package var secondsApart: TimeInterval { abs(funding.message.receivedAt.timeIntervalSince(issuer.message.receivedAt)) }
    package var preferredRecordID: String {
        issuer.record.manuallyEdited && !funding.record.manuallyEdited ? issuer.record.id : funding.record.id
    }

    private enum Role { case funding, issuer }
    private static let maximumReceiptGap: TimeInterval = 10 * 60

    private static func role(_ transaction: Transaction, message: Message) -> Role? {
        guard transaction.direction == .debit, transaction.type == .cardPayment else { return nil }
        switch transaction.bank {
        case .idfc where transaction.resolvedIDFCDualVerbDebit && transaction.merchant == "CRED": return .funding
        case .axis where Parser.isAxisCardPaymentReceipt(message.text): return .issuer
        default: return nil
        }
    }

    static func suggestions(messages: [Message], recordsBySource: [String: TransactionRecord]) -> [Self] {
        var funding: [(amount: Int64, receipt: Receipt)] = []
        var issuerByAmount: [Int64: [Receipt]] = [:]
        for message in messages {
            let source = ImportIdentity.source(message)
            guard let record = recordsBySource[source.key], record.valid, !record.needsReview,
                  record.type == .cardPayment, record.linkedCardPaymentID == nil,
                  let transaction = Parser.parse(message), let role = role(transaction, message: message) else { continue }
            let receipt = Receipt(record: record, message: message, source: source)
            switch role {
            case .funding: funding.append((transaction.amountPaise, receipt))
            case .issuer: issuerByAmount[transaction.amountPaise, default: []].append(receipt)
            }
        }

        var pairs: [ID: Self] = [:]
        for item in funding {
            for issuer in issuerByAmount[item.amount] ?? [] where item.receipt.record.id != issuer.record.id {
                let pair = Self(funding: item.receipt, issuer: issuer)
                guard pair.secondsApart <= maximumReceiptGap,
                      pair.secondsApart < (pairs[pair.id]?.secondsApart ?? .infinity) else { continue }
                pairs[pair.id] = pair
            }
        }
        return pairs.values.sorted {
            if $0.funding.message.receivedAt != $1.funding.message.receivedAt {
                return $0.funding.message.receivedAt > $1.funding.message.receivedAt
            }
            if $0.secondsApart != $1.secondsApart { return $0.secondsApart < $1.secondsApart }
            return ($0.id.funding, $0.id.issuer) < ($1.id.funding, $1.id.issuer)
        }
    }
}

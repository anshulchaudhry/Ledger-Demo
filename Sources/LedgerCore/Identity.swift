import Foundation
import CryptoKit

package struct SourceIdentity: Sendable, Equatable {
    package let key: String
    package let guid: String?
}

package enum ImportIdentity {
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    package static func source(_ message: Message) -> SourceIdentity {
        let guid = message.guid.isEmpty ? nil : message.guid
        let fallback = "\(message.sender)|\(message.receivedAt.timeIntervalSince1970)|\(message.text)"
        return SourceIdentity(key: hash(guid.map { "guid-v1|\($0)" } ?? "source-v1|\(fallback)"), guid: guid)
    }

    // Preserve the proven CLI's reference / exact normalized-text policy.
    // Persist only hashes; never derive keys from manually edited fields.
    package static func duplicate(_ message: Message, transaction: Transaction) -> String {
        if let reference = transaction.reference {
            return hash("ref-v1|\(transaction.bank.rawValue)|\(transaction.direction.rawValue)|\(transaction.amountPaise)|\(reference)")
        }
        let minute = Int(message.receivedAt.timeIntervalSince1970 / 60)
        let normalized = message.text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return hash("body-v1|\(message.sender.uppercased())|\(minute)|\(normalized)")
    }
}

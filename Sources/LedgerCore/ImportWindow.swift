import Foundation

package struct ImportWindow: Equatable, Sendable {
    package let start: Date
    package let endExclusive: Date

    package static let defaultStart = TransactionRecord.calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
    package static let legacy = ImportWindow(start: Importer.start, endExclusive: Importer.endExclusive)

    package init?(from: Date, through: Date) {
        let calendar = TransactionRecord.calendar
        let start = calendar.startOfDay(for: from)
        let lastDay = calendar.startOfDay(for: through)
        guard start <= lastDay, let end = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return nil }
        self.init(start: start, endExclusive: end)
    }

    init(start: Date, endExclusive: Date) {
        self.start = start
        self.endExclusive = endExclusive
    }

    package var through: Date {
        TransactionRecord.calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: endExclusive.timeIntervalSinceReferenceDate.nextDown))
    }
    package func contains(_ date: Date) -> Bool { date >= start && date < endExclusive }
    package func endingBefore(_ cutoff: Date) -> Self? {
        let end = min(endExclusive, cutoff)
        return end > start ? Self(start: start, endExclusive: end) : nil
    }
    package var scannedRangeLabel: String {
        let calendar = TransactionRecord.calendar
        let date = TransactionRecord.dateStyle.year()
        let time = date.hour().minute()
        let from = start.formatted(start == calendar.startOfDay(for: start) ? date : time)
        let until = endExclusive == calendar.startOfDay(for: endExclusive) ? through.formatted(date) : endExclusive.formatted(time)
        return "\(from) – \(until)"
    }

    static func merged(_ windows: [Self]) -> [Self] {
        var result: [Self] = []
        for window in windows.sorted(by: { $0.start < $1.start }) {
            if let previous = result.last, window.start <= previous.endExclusive {
                result[result.count - 1] = Self(start: previous.start, endExclusive: max(previous.endExclusive, window.endExclusive))
            } else {
                result.append(window)
            }
        }
        return result
    }
}

package struct ImportHistory: Sendable {
    package struct Scan: Sendable {
        package let window: ImportWindow
        package let completedAt: Date
        package let result: ImportResult
        package var scannedRangeLabel: String { (window.endingBefore(completedAt) ?? window).scannedRangeLabel }
    }

    package let windows: [ImportWindow]
    package let scannedWindows: [ImportWindow]
    package let lastScan: Scan?
    package let lastRefreshAt: Date?
    package let refreshThrough: Date?
    package var sourceWindows: [ImportWindow] { ImportWindow.merged([.legacy] + windows) }

    package func refreshWindow(now: Date) -> ImportWindow? {
        let floor = ImportWindow.defaultStart
        guard now > floor else { return nil }
        // Messages can sync after a scan with an older receipt timestamp.
        // Stable source identities make a two-day overlap safe to recheck.
        let previous = min(refreshThrough ?? floor, now)
        let overlapStart = previous.addingTimeInterval(-48 * 60 * 60)
        return ImportWindow(start: max(floor, overlapStart), endExclusive: now)
    }
}

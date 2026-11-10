import SwiftUI
import AppKit
import LedgerCore

// Semantic colors inherit macOS appearance. Changing appearance never changes
// a view identity, navigation selection or edit session.
enum LedgerStyle {
    private static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
        })
    }
    static let canvas = color(0xF6F2E9, 0x23221E)
    static let paper = color(0xFFFDF8, 0x2C2E27)
    static let navigation = color(0xEEEAE0, 0x1C1D19)
    static let ink = color(0x282D28, 0xF0E9DC)
    static let muted = color(0x63685D, 0xBEB8AC)
    static let accent = color(0x365740, 0xADC4A8)
    static let actionText = color(0xFFFDF8, 0x1C1D19)
    static let selection = color(0xDFE5D8, 0x394536)
    static let line = color(0xDDDCD2, 0x44463D)
    static let warning = color(0x99501D, 0xE5B56A)
    static let warningSurface = color(0xF5E9D5, 0x3D3423)
    static let danger = color(0xA63F2C, 0xEFAB94)
    static let title = Font.system(size: 30, weight: .semibold, design: .serif)
    static let section = Font.system(size: 21, weight: .semibold, design: .serif)
}

struct LedgerPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 9)
            .foregroundStyle(LedgerStyle.actionText)
            .background(LedgerStyle.accent.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.5)
            .ledgerClickableCursor()
    }
}
extension View {
    func ledgerCard(padding: CGFloat = 20) -> some View {
        self.padding(padding).background(LedgerStyle.paper, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(LedgerStyle.line.opacity(0.65)) }
    }
}
extension SpendingCategory {
    var symbol: String {
        switch self {
        case .uncategorized: "ellipsis.circle"
        case .foodDining: "fork.knife"
        case .groceries: "cart"
        case .shopping: "bag"
        case .transportation: "tram"
        case .fuel: "fuelpump"
        case .entertainment: "play.circle"
        case .sportsGames: "sportscourt"
        case .billsUtilities: "bolt"
        case .travel: "airplane"
        case .health: "cross.case"
        case .subscriptions: "arrow.trianglehead.2.clockwise.rotate.90"
        case .investments: "chart.line.uptrend.xyaxis"
        case .incomeSalary: "banknote"
        }
    }
    var displayName: String { label }
    var chartColor: Color {
        switch self {
        case .foodDining: Color(red: 0.45, green: 0.61, blue: 0.48)
        case .groceries: Color(red: 0.65, green: 0.71, blue: 0.56)
        case .subscriptions: Color(red: 0.69, green: 0.56, blue: 0.74)
        case .shopping: Color(red: 0.57, green: 0.58, blue: 0.76)
        case .transportation: Color(red: 0.43, green: 0.64, blue: 0.70)
        case .fuel: Color(red: 0.77, green: 0.58, blue: 0.39)
        case .entertainment: Color(red: 0.76, green: 0.53, blue: 0.59)
        case .sportsGames: Color(red: 0.24, green: 0.64, blue: 0.53)
        case .billsUtilities: Color(red: 0.76, green: 0.68, blue: 0.38)
        case .travel: Color(red: 0.40, green: 0.55, blue: 0.70)
        case .health: Color(red: 0.67, green: 0.44, blue: 0.38)
        case .investments: Color(red: 0.38, green: 0.48, blue: 0.74)
        case .uncategorized: Color(red: 0.62, green: 0.63, blue: 0.59)
        case .incomeSalary: Color(red: 0.42, green: 0.65, blue: 0.58)
        }
    }
}

struct LedgerNotice: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(LedgerStyle.warning)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.medium))
                if let detail { Text(detail).font(.caption).foregroundStyle(LedgerStyle.muted) }
            }
            Spacer(minLength: 0)
        }.padding(12).background(LedgerStyle.warningSurface, in: RoundedRectangle(cornerRadius: 8))
    }
}

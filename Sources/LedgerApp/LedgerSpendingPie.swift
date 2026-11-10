import SwiftUI
import Charts
import LedgerCore

struct LedgerPieSlice: Identifiable {
    let category: SpendingCategory
    let total: MonthlySummary.Total
    var id: SpendingCategory { category }
}

// Pointer updates stay inside this view, so hovering doesn't recalculate the
// page's monthly summary or change its navigation/transaction selection.
struct LedgerSpendingPie: View {
    let slices: [LedgerPieSlice]
    let select: (SpendingCategory) -> Void
    private struct Hover {
        let category: SpendingCategory
        let location: CGPoint
    }
    @State private var hover: Hover?

    var body: some View {
        Chart(slices) { slice in
            SectorMark(angle: .value("Amount in paise", slice.total.amountPaise), angularInset: 1)
                .foregroundStyle(slice.category.chartColor)
                .opacity(hover == nil || hover?.category == slice.category ? 1 : 0.7)
                .accessibilityLabel(slice.category.displayName)
                .accessibilityValue(slice.total.formattedAmount)
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let plot = proxy.plotFrame.map { geometry[$0] } ?? CGRect(origin: .zero, size: proxy.plotSize)
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if let category = category(at: location, plot: plot, proxy: proxy) {
                                hover = Hover(category: category, location: location)
                                LedgerPointer.clickable(true)
                            } else { hover = nil; LedgerPointer.clickable(false) }
                        case .ended: hover = nil; LedgerPointer.clickable(false)
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { tap in
                        if let category = category(at: tap.location, plot: plot, proxy: proxy) { select(category) }
                    })
                    .overlay(alignment: .topLeading) {
                        if let hover, let slice = slices.first(where: { $0.category == hover.category }) {
                            tooltip(slice)
                                .position(tooltipPosition(near: hover.location, in: geometry.size))
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Confirmed spending by category")
        .onDisappear { if hover != nil { LedgerPointer.clickable(false) }; hover = nil }
    }

    private func category(at location: CGPoint, plot: CGRect, proxy: ChartProxy) -> SpendingCategory? {
        let point = CGPoint(x: location.x - plot.minX, y: location.y - plot.minY)
        let distance = hypot(point.x - plot.width / 2, point.y - plot.height / 2)
        guard distance <= min(plot.width, plot.height) / 2,
              let amount = proxy.value(atAngle: proxy.angle(at: point), as: Int64.self), amount >= 0 else { return nil }
        var upperBound: Int64 = 0
        for slice in slices {
            upperBound += slice.total.amountPaise
            if amount < upperBound { return slice.category }
        }
        return nil
    }

    private func tooltip(_ slice: LedgerPieSlice) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle().fill(slice.category.chartColor).frame(width: 8, height: 8)
                Text(slice.category.displayName).font(.callout.weight(.medium))
            }
            Text(slice.total.formattedAmount).font(.title3.weight(.semibold)).monospacedDigit()
        }.frame(width: 190, alignment: .leading).padding(12)
            .foregroundStyle(LedgerStyle.ink)
            .background(LedgerStyle.paper, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(LedgerStyle.line) }
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func tooltipPosition(near pointer: CGPoint, in size: CGSize) -> CGPoint {
        let halfWidth: CGFloat = 107, halfHeight: CGFloat = 40
        let x = min(max(pointer.x + halfWidth + 12, halfWidth + 4), size.width - halfWidth - 4)
        let preferredY = pointer.y > 96 ? pointer.y - halfHeight - 12 : pointer.y + halfHeight + 12
        let y = min(max(preferredY, halfHeight + 4), size.height - halfHeight - 4)
        return CGPoint(x: x, y: y)
    }
}

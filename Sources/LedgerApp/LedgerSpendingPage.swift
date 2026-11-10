import SwiftUI
import LedgerCore

struct LedgerSpendingPage: View {
    @ObservedObject var model: TransactionsModel
    @Binding var month: LedgerMonth
    let open: (MonthlyTransactionFilter) -> Void
    let showDataStatus: () -> Void
    private var months: [LedgerMonth] {
        var values = Set(model.transactions.map { LedgerMonth(containing: $0.date) })
        var current = LedgerMonth(containing: ImportWindow.defaultStart)
        let currentMonth = LedgerMonth(containing: Date())
        while current <= currentMonth { values.insert(current); current = current.offset(1) }
        for window in model.importHistory?.windows ?? [] {
            values.insert(LedgerMonth(containing: window.start))
            values.insert(LedgerMonth(containing: window.through))
        }
        values.insert(month)
        return values.sorted(by: >)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Monthly spending").font(LedgerStyle.title)
                Spacer()
                Button { month = month.offset(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous month")
                LedgerSelect("Month", selection: $month, options: months, showsTitle: false) { $0.label }
                    .frame(width: 180)
                Button { month = month.offset(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next month")
            }
            HStack(spacing: 12) {
                Button {
                    Task { await model.importMessages() }
                } label: {
                    Label("Refresh now", systemImage: "arrow.clockwise")
                }.disabled(model.busy).help("Import recently received bank SMS on this Mac.")
                Text(model.importHistory?.lastRefreshAt == nil ? model.lastRefreshLabel : "Last refresh · \(model.lastRefreshLabel)")
                    .font(.caption).foregroundStyle(LedgerStyle.muted)
                Button(action: showDataStatus) {
                    Label("Data status", systemImage: "info.circle").font(.callout)
                }.buttonStyle(LedgerPlainButton()).disabled(model.busy)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let summary = try? MonthlySummary(month: month, records: model.transactions) {
                        summaryContent(summary)
                    } else {
                        ContentUnavailableView("Unable to total these amounts", systemImage: "exclamationmark.triangle",
                            description: Text("Review this month’s transactions before using the summary."))
                        Button("View month’s transactions") { show(.all) }
                    }
                }.padding(.trailing, 8).padding(.bottom, 16)
            }
        }.padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    @ViewBuilder private func summaryContent(_ summary: MonthlySummary) -> some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Confirmed expenses").font(.headline).foregroundStyle(LedgerStyle.muted)
                HStack(spacing: 20) {
                    Text(summary.total(.expenses).formattedAmount).font(.system(size: 44, weight: .medium, design: .serif)).monospacedDigit()
                    Button("View \(summary.total(.expenses).count) expenses") { show(.expenses) }.disabled(summary.total(.expenses).count == 0)
                }
            }
            Spacer(minLength: 0)
            Rectangle().fill(LedgerStyle.line).frame(width: 1, height: 38)
            HStack(spacing: 20) {
                recordCount(summary.records.count, label: "Saved records", bucket: .all)
                recordCount(summary.excludedCount, label: "Outside expenses", bucket: .excluded)
                recordCount(summary.total(.needsReview).count, label: "Needs Review", bucket: .needsReview)
            }
        }
        categoryBreakdown(summary)
        VStack(alignment: .leading, spacing: 18) {
            Text("Separate from spending").font(LedgerStyle.section)
            row(.category(.incomeSalary), summary: summary, symbol: SpendingCategory.incomeSalary.symbol)
            Text("Income / Salary includes only money in that you tag. Tagged income is also included under Incoming payments or Transfers.")
                .font(.caption).foregroundStyle(LedgerStyle.muted)
            Divider().overlay(LedgerStyle.line)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 20) {
                row(.refunds, summary: summary)
                row(.incomingPayments, summary: summary)
                row(.transfers, summary: summary)
                row(.cardPayments, summary: summary)
            }
            Text("Refunds aren’t subtracted from expenses. Incoming payments aren’t assumed to be income. Transfers and card payments stay outside spending.")
                .font(.caption).foregroundStyle(LedgerStyle.muted).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).ledgerCard()
        VStack(alignment: .leading, spacing: 8) {
            if let first = summary.firstDate, let last = summary.lastDate {
                Text("Saved dates this month: \(date(first)) – \(date(last))")
            }
            Text("\(summary.receiptOrEditedDateCount) receipt-time or manually corrected dates. A category does not resolve Needs Review.")
        }.font(.caption).foregroundStyle(LedgerStyle.muted)
    }

    private func recordCount(_ count: Int, label: String, bucket: MonthlyBucket) -> some View {
        Button { show(bucket) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(count, format: .number).font(.title3.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(bucket == .needsReview && count > 0 ? LedgerStyle.warning : LedgerStyle.ink)
                HStack(spacing: 5) {
                    Text(label).font(.caption)
                    Image(systemName: "chevron.right").font(.caption2).opacity(count == 0 ? 0 : 1)
                }.foregroundStyle(LedgerStyle.muted)
            }.fixedSize(horizontal: true, vertical: false).padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(LedgerPlainButton()).disabled(count == 0)
            .accessibilityLabel("\(count) \(label)")
    }

    private func spendingCategories(_ summary: MonthlySummary) -> [SpendingCategory] {
        SpendingCategory.expenseCategories.filter { summary.total(.category($0)).amountPaise > 0 }
            .sorted {
                let left = summary.total(.category($0)).amountPaise
                let right = summary.total(.category($1)).amountPaise
                return left == right ? $0.rawValue < $1.rawValue : left > right
            }
    }

    private func categoryBreakdown(_ summary: MonthlySummary) -> some View {
        let categories = spendingCategories(summary)
        let expenseTotal = summary.total(.expenses).amountPaise
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Spending by category").font(LedgerStyle.section)
                Spacer()
                Text("Confirmed expenses only").font(.caption).foregroundStyle(LedgerStyle.muted)
            }
            if categories.isEmpty {
                ContentUnavailableView("No confirmed expenses to chart", systemImage: "chart.pie",
                    description: Text(summary.records.isEmpty
                        ? "No saved transactions this month."
                        : "Review uncertain transactions or choose another month."))
                    .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                HStack(spacing: 44) {
                    LedgerSpendingPie(slices: categories.map {
                        LedgerPieSlice(category: $0, total: summary.total(.category($0)))
                    }, select: { show(.category($0)) })
                        .id(month)
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 360)
                        .frame(height: 280)
                    VStack(spacing: 4) {
                        ForEach(categories, id: \.self) { category in
                            let total = summary.total(.category(category))
                            Button { show(.category(category)) } label: {
                                HStack(spacing: 12) {
                                    Circle().fill(category.chartColor).frame(width: 10, height: 10)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(category.displayName).font(.callout.weight(.medium))
                                        Text("\(total.count) \(total.count == 1 ? "transaction" : "transactions") · \(share(total.amountPaise, of: expenseTotal))")
                                            .font(.caption).foregroundStyle(LedgerStyle.muted)
                                    }
                                    Spacer(minLength: 12)
                                    Text(total.formattedAmount).font(.callout.weight(.medium)).monospacedDigit()
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(LedgerStyle.muted)
                                }.padding(.vertical, 10).contentShape(Rectangle())
                            }.buttonStyle(LedgerPlainButton())
                                .accessibilityLabel("\(category.displayName): \(total.formattedAmount), \(share(total.amountPaise, of: expenseTotal)). View \(total.count) \(total.count == 1 ? "transaction" : "transactions")")
                        }
                    }.frame(maxWidth: .infinity)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).ledgerCard(padding: 24)
    }

    private func share(_ amount: Int64, of total: Int64) -> String {
        // Floating point is used only for presentation; money totals stay in paise.
        (Double(amount) / Double(total)).formatted(.percent.precision(.fractionLength(1)))
    }
    private func row(_ bucket: MonthlyBucket, summary: MonthlySummary, symbol: String? = nil) -> some View {
        let total = summary.total(bucket)
        return Button { show(bucket) } label: {
            HStack(spacing: 10) {
                if let symbol { Image(systemName: symbol).foregroundStyle(LedgerStyle.accent).frame(width: 18) }
                Text(bucket.label)
                Spacer(minLength: 10)
                Text(bucket == .transfers ? "\(total.count) \(total.count == 1 ? "record" : "records")" : total.formattedAmount).monospacedDigit()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(LedgerStyle.muted)
            }.font(.callout).contentShape(Rectangle())
        }.buttonStyle(LedgerPlainButton()).disabled(total.count == 0)
            .accessibilityLabel("\(bucket.label): \(total.count) \(total.count == 1 ? "record" : "records")\(bucket == .transfers ? "" : ", \(total.formattedAmount)"). View transactions")
    }
    private func show(_ bucket: MonthlyBucket) { open(MonthlyTransactionFilter(month: month, bucket: bucket)) }
    private func date(_ value: Date) -> String { value.formatted(TransactionRecord.dateStyle.year()) }
}

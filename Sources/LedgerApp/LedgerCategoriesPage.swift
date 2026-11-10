import SwiftUI
import LedgerCore

struct LedgerCategoriesPage: View {
    @ObservedObject var model: TransactionsModel
    let review: (CategorizationPipeline.UnknownMerchant) -> Void
    let suggestions: () -> Void
    @State private var report: CategorizationPipeline.Coverage?
    private struct Input: Equatable, Sendable { let records: [TransactionRecord]; let rules: [MerchantCategoryRule] }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Categories").font(LedgerStyle.title)
                    Text("Your choices come first.").foregroundStyle(LedgerStyle.muted)
                }
                Spacer()
                Button("Review category suggestions", action: suggestions).disabled(model.busy)
            }
            if let report {
                HStack(spacing: 24) {
                    Text("\(report.categorized) categorized")
                    Text("\(report.uncategorized) in \(SpendingCategory.uncategorized.label)")
                    Text("\(report.needsReview) Needs Review").foregroundStyle(LedgerStyle.warning)
                }.font(.callout)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Category suggestions").font(LedgerStyle.section)
                            Text("Review recognized matches before applying them. Assigned categories and saved edits stay protected.")
                                .font(.callout).foregroundStyle(LedgerStyle.muted)
                            Button("Review suggestions", action: suggestions).disabled(model.busy)
                        }.frame(maxWidth: .infinity, alignment: .leading).ledgerCard()
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Merchants to organize").font(LedgerStyle.section)
                            Text("Choose a category on a transaction, then optionally remember it for future reliable matches.")
                                .font(.callout).foregroundStyle(LedgerStyle.muted)
                            if report.unknown.isEmpty {
                                Text("No unmatched eligible merchants. Category hints and saved edits can still be reviewed separately.")
                                    .foregroundStyle(LedgerStyle.muted).padding(.vertical, 16)
                            }
                        }
                        ForEach(report.unknown) { group in
                            HStack(spacing: 16) {
                                Image(systemName: "tag").foregroundStyle(LedgerStyle.accent)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(group.merchant).fontWeight(.medium)
                                    Text("\(group.count) \(group.count == 1 ? "record" : "records") in \(SpendingCategory.uncategorized.label)")
                                        .font(.caption).foregroundStyle(LedgerStyle.muted)
                                }
                                Spacer()
                                // This page is no longer a sheet: navigation replaces
                                // it directly, using the cached group's exact IDs.
                                Button("Review transactions") { review(group) }.disabled(model.busy)
                            }.ledgerCard(padding: 16)
                        }
                        LedgerNotice(title: "A category does not resolve Needs Review.",
                            detail: "\(report.pendingCategories) \(report.pendingCategories == 1 ? "review record already has" : "review records already have") a purpose category. Direction and type still need checking before spending inclusion.")
                        DisclosureGroup("How local categorization works") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Saved choices → Your merchant rules → Recognized services → Review hints → Unmatched merchants")
                                Text("\(report.automaticReady) ready for matching · \(report.protectedUncategorized) saved edits protected · \(report.reviewHints) hints needing approval · \(report.conflictingRules) conflicting rules · \(report.nonExpenseUncategorized) other types or incomplete details")
                                Text("Rules match the identified merchant or recipient, not the bank’s SMS sender. Existing saved categories take priority. Unrecognized messages that never became transactions require separate parser support.")
                                Button(model.busy ? "Working locally…" : "Run local categorization") { Task { await model.categorizeAutomatically() } }
                                    .disabled(model.busy)
                                DisclosureGroup("Recognized services") {
                                    ForEach(MerchantCatalog.entries.filter { $0.automatic }, id: \.id) { entry in
                                        Text("\(entry.name) → \(entry.category.label)")
                                    }
                                }
                            }.font(.callout).foregroundStyle(LedgerStyle.muted).padding(.top, 12)
                        }
                    }.padding(.trailing, 8).padding(.bottom, 20)
                }
            } else { ProgressView("Preparing category groups…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(28)
        .task(id: Input(records: model.transactions, rules: model.rules)) {
            report = nil
            let records = model.transactions, rules = model.rules
            let worker = Task.detached(priority: .userInitiated) { CategorizationPipeline(rules: rules).coverage(records) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            report = result
        }
    }
}

import SwiftUI
import AppKit
import LedgerCore

struct ReviewDiagnosticsView: View {
    @ObservedObject var model: TransactionsModel
    let open: (ReviewDiagnostics.Group) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sources: ReviewDiagnostics.SourceAnalysis?
    @State private var analyzing = false
    @State private var analysisTask: Task<Void, Never>?
    @State private var analysisError = false
    @State private var copied = false

    var body: some View {
        let records = model.transactions
        let report = ReviewDiagnostics(records: records)
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Why these need review").font(LedgerStyle.title)
                    Text("A local breakdown. Nothing is changed automatically.")
                        .font(.callout).foregroundStyle(LedgerStyle.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if report.total == 0 {
                        ContentUnavailableView("No transactions need review", systemImage: "checkmark.circle",
                            description: Text("This describes your saved records. Missing or unparsed SMS may still leave gaps."))
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(report.total) transactions need review").font(LedgerStyle.section)
                            Text("All saved dates · Independent of transaction filters")
                                .font(.caption).foregroundStyle(LedgerStyle.muted)
                            Text("\(report.categorized) already categorized · \(report.savedCorrections) saved corrections protected")
                                .font(.callout).foregroundStyle(LedgerStyle.muted)
                            Text("Categories do not confirm payment type. These records stay outside spending until their direction and type are confirmed.")
                                .font(.callout)
                        }.frame(maxWidth: .infinity, alignment: .leading).ledgerCard()

                        Text("What needs a decision").font(LedgerStyle.section)
                        ForEach(report.reasons) { group in
                            groupCard(group, explanation: group.reason?.explanation ?? "")
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            Text("By bank").font(LedgerStyle.section)
                            ForEach(report.banks) { group in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.title).fontWeight(.medium)
                                        Text(bankReasons(group, report: report))
                                            .font(.caption).foregroundStyle(LedgerStyle.muted)
                                    }
                                    Spacer()
                                    Button("Review \(group.count)") { open(group) }.disabled(model.busy)
                                        .accessibilityLabel("Review \(group.count) \(group.title) transactions")
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).ledgerCard()

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Look for recurring SMS wording").font(LedgerStyle.section)
                            Text("Optional: scan previously imported receipt dates on this Mac and inspect the linked SMS for these review records. This leaves saved records intact. SMS text is kept in memory for this report.")
                                .font(.callout).foregroundStyle(LedgerStyle.muted)
                            if analyzing {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text("Analyzing locally…").font(.callout)
                                    Spacer()
                                    Button("Cancel analysis") { cancelAnalysis() }
                                }
                            } else {
                                Button(model.demo ? "Analyze fictional SMS" : sources == nil ? "Analyze original SMS on this Mac" : "Analyze again") {
                                    analyze(records)
                                }.buttonStyle(LedgerPrimaryButton()).disabled(model.busy)
                            }
                            if let failure = sources?.failure {
                                Text(failure.explanation).font(.callout).foregroundStyle(LedgerStyle.warning)
                            }
                            if analysisError {
                                Text("The local analysis could not finish. Your saved records are unchanged. You can still use the review groups above.")
                                    .font(.callout).foregroundStyle(LedgerStyle.warning)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).ledgerCard()
                        if let sources, sources.failure == nil {
                            Text("Patterns in the original SMS").font(LedgerStyle.section)
                            Text("These groups explain recognition limits; they do not establish accuracy or automatically confirm a transaction.")
                                .font(.callout).foregroundStyle(LedgerStyle.muted)
                            ForEach(sources.groups(records: records)) { group in
                                let finding = ReviewDiagnostics.SourceFinding(rawValue: group.id)!
                                groupCard(group, explanation: finding.explanation,
                                    detail: report.banks.compactMap { bank in
                                        let count = bank.transactionIDs.intersection(group.transactionIDs).count
                                        return count == 0 ? nil : "\(bank.title): \(count)"
                                    }.joined(separator: " · "))
                            }
                        }
                    }
                    LedgerNotice(title: "This report covers saved review records only.",
                        detail: "This report uses saved review records and their available sources. Receipt scans can leave gaps in coverage.")
                }.padding(.trailing, 6).padding(.bottom, 8)
            }
            HStack(spacing: 12) {
                Button(copied ? "Counts copied" : "Copy counts only") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(report.countsSummary(records: records, sources: sources), forType: .string)
                }.disabled(analyzing)
                Text("No SMS text, names, amounts or account details.")
                    .font(.caption).foregroundStyle(LedgerStyle.muted)
                Spacer(minLength: 0)
            }
        }.padding(24).frame(width: 780, height: 720)
            .foregroundStyle(LedgerStyle.ink).background(LedgerStyle.canvas)
            .buttonStyle(LedgerSecondaryButton())
            .onChange(of: records) { _, _ in
                cancelAnalysis(); sources = nil; copied = false; analysisError = false
            }
            .onDisappear { cancelAnalysis() }
    }

    private func groupCard(_ group: ReviewDiagnostics.Group, explanation: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 18) {
                Text(group.title).font(.headline)
                Spacer()
                Text("\(group.count)").font(.title3.monospacedDigit()).foregroundStyle(LedgerStyle.warning)
            }
            Text(explanation).font(.callout).foregroundStyle(LedgerStyle.muted)
            if let detail { Text(detail).font(.caption).foregroundStyle(LedgerStyle.muted) }
            Button("Review \(group.count) \(group.count == 1 ? "transaction" : "transactions")") { open(group) }
                .disabled(model.busy).accessibilityLabel("\(group.title). Review \(group.count) transactions")
        }.frame(maxWidth: .infinity, alignment: .leading).ledgerCard(padding: 16)
    }

    private func bankReasons(_ group: ReviewDiagnostics.Group, report: ReviewDiagnostics) -> String {
        report.reasons.compactMap { reason in
            let count = reason.transactionIDs.intersection(group.transactionIDs).count
            return count == 0 ? nil : "\(reason.title): \(count)"
        }.joined(separator: " · ")
    }

    private func cancelAnalysis() {
        analysisTask?.cancel(); analysisTask = nil; analyzing = false
    }
    private func analyze(_ records: [TransactionRecord]) {
        cancelAnalysis(); sources = nil; copied = false; analysisError = false; analyzing = true
        analysisTask = Task {
            do {
                let result = try await model.analyzeReviewSources(records: records)
                guard !Task.isCancelled, model.transactions == records else { return }
                sources = result
            } catch is CancellationError { return }
              catch {
                guard !Task.isCancelled, model.transactions == records else { return }
                analysisError = true
            }
            analyzing = false
        }
    }
}

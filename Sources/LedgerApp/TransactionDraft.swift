import SwiftUI
import AppKit
import LedgerCore

@MainActor
final class TransactionDraft: ObservableObject {
    enum Field: Hashable { case merchant, amount, date, bank, direction, type, category }
    @Published var baseline: TransactionRecord?
    @Published var record: TransactionRecord?
    @Published var amount = ""
    @Published var editing = false
    @Published var saving = false
    @Published var remember = false
    @Published var focus: Field?

    var correction: TransactionRecord? {
        guard var value = record, let amountPaise = TransactionRecord.paise(from: amount) else { return nil }
        value.amountPaise = amountPaise
        value.merchant = value.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.date != baseline?.date { value.dateFromSMS = false }
        return value.valid ? value : nil
    }
    var dirty: Bool {
        guard editing, let record, let baseline else { return false }
        return record != baseline || TransactionRecord.paise(from: amount) != baseline.amountPaise || remember
    }
    var canRemember: Bool {
        guard let value = correction else { return false }
        return value.isConfirmedExpense && MerchantIntelligence.ruleKey(for: value.merchant) != nil
    }
    func select(_ value: TransactionRecord?) {
        baseline = value; record = value
        amount = value.map { NSDecimalNumber(decimal: Decimal($0.amountPaise) / 100).stringValue } ?? ""
        editing = false; remember = false; focus = nil
    }
    func begin(_ field: Field) { editing = true; focus = field }
    func cancel() { select(baseline) }
}

// macOS quit and native-window-close both protect the same unsaved drafts.
// No financial fields are included in the alert.
@MainActor
final class LedgerLifecycle: NSObject, NSApplicationDelegate {
    static var sessions: [UUID: TransactionDraft] = [:]
    static func allowDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "Your transaction has unsaved edits. Keep editing to save them first."
        alert.addButton(withTitle: "Keep editing")
        alert.addButton(withTitle: "Discard changes")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.sessions.values.contains(where: \.saving) else { return .terminateCancel }
        guard Self.sessions.values.contains(where: \.dirty) else { return .terminateNow }
        return Self.allowDiscard() ? .terminateNow : .terminateCancel
    }
}

struct LedgerWindowGuard: NSViewRepresentable {
    @ObservedObject var draft: TransactionDraft
    func makeNSView(context: Context) -> GuardView { GuardView(draft: draft) }
    func updateNSView(_ view: GuardView, context: Context) { view.draft = draft }
    @MainActor final class GuardView: NSView, NSWindowDelegate {
        var draft: TransactionDraft
        nonisolated(unsafe) weak var previousDelegate: NSWindowDelegate?
        init(draft: TransactionDraft) { self.draft = draft; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.delegate !== self else { return }
            previousDelegate = window.delegate
            window.delegate = self
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard !draft.saving else { return false }
            guard !draft.dirty || LedgerLifecycle.allowDiscard() else { return false }
            draft.cancel()
            return previousDelegate?.windowShouldClose?(sender) ?? true
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            previousDelegate?.responds(to: selector) == true ? previousDelegate : super.forwardingTarget(for: selector)
        }
    }
}

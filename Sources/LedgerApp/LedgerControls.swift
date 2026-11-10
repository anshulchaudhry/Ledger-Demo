import SwiftUI
import AppKit

@MainActor
enum LedgerPointer {
    static func clickable(_ active: Bool) { (active ? NSCursor.pointingHand : NSCursor.arrow).set() }
}

private struct LedgerClickableCursor: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var inside = false
    func body(content: Content) -> some View {
        content
            .onHover { active in inside = active; LedgerPointer.clickable(active && enabled) }
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !inside { inside = true }
                    LedgerPointer.clickable(enabled)
                case .ended:
                    inside = false; LedgerPointer.clickable(false)
                }
            }
            .onChange(of: enabled) { _, value in if inside { LedgerPointer.clickable(value) } }
            .onDisappear { if inside { LedgerPointer.clickable(false) } }
    }
}
extension View {
    func ledgerClickableCursor() -> some View { modifier(LedgerClickableCursor()) }
}

struct LedgerPlainButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .ledgerClickableCursor()
    }
}

struct LedgerDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.caption2)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0)).accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(LedgerPlainButton())
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content.padding(.top, 10).padding(.leading, 18) }
        }
    }
}

struct LedgerSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LedgerButtonSurface(configuration: configuration)
    }
}

private struct LedgerButtonSurface: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.controlSize) private var size
    @State private var hovering = false
    var body: some View {
        configuration.label.font(.callout.weight(.medium))
            .foregroundStyle(configuration.role == .destructive ? LedgerStyle.danger : LedgerStyle.ink)
            .padding(.horizontal, 12).padding(.vertical, size == .small ? 5 : 8)
            .background(configuration.isPressed || hovering ? LedgerStyle.selection : LedgerStyle.paper,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? LedgerStyle.accent : LedgerStyle.line) }
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovering = $0 }
            .focusEffectDisabled()
            .ledgerClickableCursor()
    }
}

// A shared selector keeps the closed control and its open choices in Ledger's
// semantic palette. Options remain real buttons for keyboard/VoiceOver access.
struct LedgerSelect<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var showsTitle = true
    @State private var presented = false
    @State private var focusedOption: Value?
    @FocusState private var menuFocused: Bool

    init(_ title: String, selection: Binding<Value>, options: [Value], showsTitle: Bool = true,
         label: @escaping (Value) -> String) {
        self.title = title; _selection = selection; self.options = options
        self.showsTitle = showsTitle; self.label = label
    }

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    if showsTitle { Text(title).font(.caption).foregroundStyle(LedgerStyle.muted) }
                    Text(label(selection)).font(.callout).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LedgerStyle.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(LedgerSecondaryButton()).focusable().focusEffectDisabled()
            .accessibilityLabel(title).accessibilityValue(label(selection))
            .accessibilityHint("Opens \(title.lowercased()) choices.")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.caption.weight(.medium)).foregroundStyle(LedgerStyle.muted)
                            .padding(.horizontal, 10).padding(.top, 6)
                        ScrollView {
                            VStack(spacing: 3) {
                                ForEach(options, id: \.self) { option in
                                    Button { choose(option) } label: {
                                        HStack(spacing: 10) {
                                            Text(label(option)).frame(maxWidth: .infinity, alignment: .leading)
                                            Image(systemName: "checkmark").font(.caption.weight(.semibold))
                                                .opacity(option == selection ? 1 : 0)
                                        }.padding(.horizontal, 10).padding(.vertical, 9)
                                    }.buttonStyle(LedgerChoiceButton(selected: option == selection, active: option == focusedOption))
                                        .id(option)
                                        .accessibilityAddTraits(option == selection ? .isSelected : [])
                                }
                            }
                        }.frame(height: min(CGFloat(options.count) * 38, 304))
                    }.padding(8).frame(width: 270)
                        .foregroundStyle(LedgerStyle.ink).background(LedgerStyle.paper)
                        .presentationBackground(LedgerStyle.paper)
                        .focusable().focusEffectDisabled().focused($menuFocused)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("\(title) choices")
                        .accessibilityValue(focusedOption.map(label) ?? label(selection))
                        .accessibilityHint("Use up and down arrows, then Return to choose. Escape closes the menu.")
                        .task {
                            await Task.yield()
                            focusedOption = selection; menuFocused = true
                            proxy.scrollTo(selection, anchor: .center)
                        }
                        .onKeyPress(.downArrow) { move(1, proxy: proxy); return .handled }
                        .onKeyPress(.upArrow) { move(-1, proxy: proxy); return .handled }
                        .onKeyPress(.return) {
                            guard let option = focusedOption else { return .ignored }
                            choose(option); return .handled
                        }
                        .onExitCommand { presented = false }
                }
            }
    }
    private func choose(_ option: Value) { presented = false; selection = option }
    private func move(_ delta: Int, proxy: ScrollViewProxy) {
        guard !options.isEmpty else { return }
        let current = options.firstIndex(of: focusedOption ?? selection) ?? 0
        let next = min(max(current + delta, 0), options.count - 1)
        focusedOption = options[next]; proxy.scrollTo(options[next])
    }
}

private struct LedgerChoiceButton: ButtonStyle {
    let selected: Bool
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        LedgerChoiceSurface(configuration: configuration, selected: selected || active)
    }
}
private struct LedgerChoiceSurface: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.isFocused) private var focused
    @State private var hovering = false
    var body: some View {
        configuration.label.font(.callout)
            .foregroundStyle(LedgerStyle.ink)
            .background(selected || focused || hovering || configuration.isPressed ? LedgerStyle.selection : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }.focusEffectDisabled().ledgerClickableCursor()
    }
}

struct LedgerTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).padding(.horizontal, 10).padding(.vertical, 8)
            .foregroundStyle(LedgerStyle.ink)
            .background(LedgerStyle.paper, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(LedgerStyle.line) }
    }
}

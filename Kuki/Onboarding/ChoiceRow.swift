import SwiftUI

/// A quiz answer: full width, paper until chosen, then raised with an ink
/// border and a checkmark — never colour alone.
struct ChoiceRow<Trailing: View>: View {
    var kanji: String?
    let title: String
    var subtitle: String?
    var tag: String?
    let selected: Bool
    var multiSelect = false
    let action: () -> Void
    @ViewBuilder var leading: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if !dynamicTypeSize.isAccessibilitySize {
                    leading
                    if let kanji {
                        Text(kanji)
                            .font(Typeface.mincho(22))
                            .foregroundStyle(Ink.inkSoft)
                            .fixedSize()
                            .frame(minWidth: 44, alignment: .leading)
                            .accessibilityHidden(true)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let tag {
                        Text(tag).kukiLabel()
                            .foregroundStyle(Ink.ink)
                    }
                    Text(title)
                        .font(Typeface.body)
                        .foregroundStyle(Ink.ink)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Ink.inkSoft)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Ink.ink)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(selected ? Ink.paperRaised : Ink.paper))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Ink.ink : Ink.hairline, lineWidth: selected ? 1.5 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .quietHover(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityHint(multiSelect ? String(localized: "Double-tap to choose. You can choose several.", comment: "Onboarding: VoiceOver hint on a multiple-choice answer") : "")
        .animation(.easeOut(duration: 0.18), value: selected)
    }
}

extension ChoiceRow where Trailing == EmptyView {
    init(kanji: String? = nil, title: String, subtitle: String? = nil, tag: String? = nil,
         selected: Bool, multiSelect: Bool = false, action: @escaping () -> Void) {
        self.init(kanji: kanji, title: title, subtitle: subtitle, tag: tag, selected: selected,
                  multiSelect: multiSelect, action: action) { EmptyView() }
    }
}

/// A small answer chip (the bedroom guess).
struct Chip: View {
    let title: String
    let accessibilityText: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typeface.body.monospacedDigit())
                .foregroundStyle(Ink.ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 18)
                .frame(minWidth: 64, minHeight: 44)
                .background(Capsule().fill(selected ? Ink.paperRaised : Ink.paper))
                .overlay(Capsule().strokeBorder(selected ? Ink.ink : Ink.hairline, lineWidth: selected ? 1.5 : 0.5))
                .contentShape(Capsule())
                .quietHover(Capsule())
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

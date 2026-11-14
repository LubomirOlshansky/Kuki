import SwiftUI

/// Layout numbers for the introduction — NowView's own, so no new tokens.
enum OnboardingMetrics {
    static func side(wide: Bool) -> CGFloat { wide ? 48 : 28 }
    static let block: CGFloat = 22
    static let titleToBody: CGFloat = 8
    static let bodyToControl: CGFloat = 18
    static let maxColumn: CGFloat = 520
    static let wideBreakpoint: CGFloat = 760
    static let maxWide: CGFloat = 1040
    static let wideTextColumn: CGFloat = 440
    /// iPhone SE, the Duo's outer display.
    static let compactHeight: CGFloat = 720
}

extension AnyTransition {
    /// `.inkDiffuse`, or a plain fade with Reduce Motion (no animating into blur).
    static func inkDiffuseOrFade(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .inkDiffuse
    }
}

// MARK: - Buttons

/// The one primary action: ink capsule, paper text.
struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typeface.body.weight(.semibold))
                .foregroundStyle(Ink.paper)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: 360, minHeight: 50)
                .background(Capsule().fill(Ink.ink))
                .contentShape(Capsule())
                .quietHover(Capsule())
        }
        .buttonStyle(QuietButtonStyle())
    }
}

/// The quiet indigo text button (as in the empty sensor view), 44 pt tall.
struct TextLinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Ink.ai)
                .multilineTextAlignment(.center)
                .frame(minHeight: 44)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .quietHover(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(QuietButtonStyle())
    }
}

/// An outlined secondary control (the simulator's window button).
struct OutlineButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
                Text(title)
            }
            .font(Typeface.body)
            .foregroundStyle(Ink.ink)
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
            .overlay(Capsule().stroke(Ink.ink, lineWidth: 1))
            .contentShape(Capsule())
            .quietHover(Capsule())
        }
        .buttonStyle(QuietButtonStyle())
    }
}

// MARK: - Text blocks

/// 息 · BREATH — the kanji accent and the screen's eyebrow word.
struct Eyebrow: View {
    let kanji: String
    let word: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(kanji).font(Typeface.mincho(22)).foregroundStyle(Ink.inkSoft)
                .accessibilityHidden(true)
            Text(word).kukiLabel()
                .accessibilityHidden(true)
        }
    }
}

/// A screen title: large, light, a header for VoiceOver.
struct ScreenTitle: View {
    let text: String
    @Environment(\.legibilityWeight) private var legibilityWeight

    var body: some View {
        Text(text)
            .font(Typeface.pageTitle(bold: legibilityWeight == .bold))
            .foregroundStyle(Ink.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A body paragraph; `ink` for the one that leads.
struct BodyText: View {
    let text: String
    var ink = false

    init(_ text: String, ink: Bool = false) {
        self.text = text
        self.ink = ink
    }

    var body: some View {
        Text(text)
            .font(Typeface.body)
            .foregroundStyle(ink ? Ink.ink : Ink.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A line that answers the user's own quiz choice.
struct PersonalLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.italic())
            .foregroundStyle(Ink.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The card on the listening screen (and the reminder offer).
struct NoteCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Ink.paperRaised))
    }
}

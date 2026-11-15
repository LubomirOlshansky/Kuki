import SwiftUI

/// "記録 History" — the kanji accent and the page's name, the only title
/// chrome a page has.
struct PageTitle<Trailing: View>: View {
    /// Decorative, shown as is in every language.
    let kanji: String
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing
    @Environment(\.legibilityWeight) private var legibilityWeight

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(kanji).font(Typeface.mincho(24)).foregroundStyle(Ink.inkSoft)
                .accessibilityHidden(true)
            Text(title).font(Typeface.pageTitle(bold: legibilityWeight == .bold)).foregroundStyle(Ink.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension PageTitle where Trailing == EmptyView {
    init(kanji: String, title: LocalizedStringKey) {
        self.init(kanji: kanji, title: title) { EmptyView() }
    }
}

/// Pointer feedback for the app's quiet custom controls. On the Mac a soft
/// wash of ink appears under the pointer (UIKit's pointer effects are an iPad
/// feature and don't show in the Mac idiom); on iPad the system highlight.
struct QuietHover<S: Shape>: ViewModifier {
    let shape: S
    @State private var hovering = false

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .background(shape.fill(Ink.hairline).opacity(hovering ? 1 : 0))
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
            }
        #else
        content.hoverEffect(.highlight)
        #endif
    }
}

extension View {
    func quietHover<S: Shape>(_ shape: S) -> some View {
        modifier(QuietHover(shape: shape))
    }
}

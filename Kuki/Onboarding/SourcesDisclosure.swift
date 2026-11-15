import SwiftUI

/// "Sources ⌄" — the studies behind a page, folded away until asked for.
struct SourcesDisclosure: View {
    let sources: [ScienceSource]
    /// Off where the page already shows the medical line in the open.
    var showsMedicalLine = true
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var medicalLine: String { String(localized: "Kūki shows what your sensor measures. It isn't a medical device.", comment: "Onboarding: Sources disclosure, disclaimer under the list of studies") }
    /// The same caveat, said once in the open on the Breath screen.
    static var medicalFinePrint: String { String(localized: "Kūki is not a medical device.", comment: "Onboarding, Breath screen: disclaimer footnote") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("Sources", comment: "Onboarding: button that unfolds the list of studies behind a page, small capitals (short)").kukiLabel()
                    Image(systemName: reduceMotion && open ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Ink.inkSoft)
                        .rotationEffect(.degrees(!reduceMotion && open ? 180 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityLabel(Text("Sources", comment: "Onboarding: button that unfolds the list of studies behind a page, small capitals (short)"))
            .accessibilityHint(Text("Shows the studies behind this page", comment: "Onboarding: VoiceOver hint of the Sources button"))
            .accessibilityValue(open
                                ? String(localized: "Expanded", comment: "Onboarding: VoiceOver value of the folded Sources list when open")
                                : String(localized: "Collapsed", comment: "Onboarding: VoiceOver value of the folded Sources list when closed"))

            if open {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sources) { source in
                        VStack(alignment: .leading, spacing: 3) {
                            Link(source.short, destination: source.url) // a citation: not translated
                                .font(.footnote)
                                .foregroundStyle(Ink.ai)
                            if let note = source.note {
                                Text(note).font(.footnote).foregroundStyle(Ink.inkSoft)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if showsMedicalLine {
                        Text(Self.medicalLine)
                            .font(.footnote)
                            .foregroundStyle(Ink.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

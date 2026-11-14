import SwiftUI

/// "Sources ⌄" — the studies behind a page, folded away until asked for.
struct SourcesDisclosure: View {
    let sources: [ScienceSource]
    /// Off where the page already shows the medical line in the open.
    var showsMedicalLine = true
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let medicalLine = "Kūki shows what your sensor measures. It isn't a medical device."
    /// The same caveat, said once in the open on the Breath screen.
    static let medicalFinePrint = "Kūki is not a medical device."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("Sources").kukiLabel()
                    Image(systemName: reduceMotion && open ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Ink.inkSoft)
                        .rotationEffect(.degrees(!reduceMotion && open ? 180 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityLabel("Sources")
            .accessibilityHint("Shows the studies behind this page")
            .accessibilityValue(open ? "Expanded" : "Collapsed")

            if open {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sources) { source in
                        VStack(alignment: .leading, spacing: 3) {
                            Link(source.short, destination: source.url)
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

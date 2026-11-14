import SwiftUI

/// 聴 — sensor → Apple Home → Kūki, what the ensō means, rooms and the
/// chime, and an honest note about when Kūki records.
struct ListenScreen: View {
    let platform: OnboardingPlatform

    var body: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.block) {
            VStack(alignment: .leading, spacing: OnboardingMetrics.titleToBody) {
                Eyebrow(kanji: "聴", word: "Listening")
                ScreenTitle(text: "How Kūki hears the air")
            }
            PipelineDiagram()
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 18) {
                feature(first: "The ensō grows with CO₂.",
                        rest: "A short stroke is clear air; a nearly closed circle means open a window.") {
                    HStack(spacing: 2) {
                        EnsoRing(fraction: 0.12, color: Ink.matcha, lineWidth: 2, animated: false).frame(width: 13, height: 13)
                        EnsoRing(fraction: 0.45, color: Ink.kincha, lineWidth: 2, animated: false).frame(width: 13, height: 13)
                        EnsoRing(fraction: 0.88, color: Ink.shu, lineWidth: 2, animated: false).frame(width: 13, height: 13)
                    }
                }
                feature(first: "Tell Kūki which room the sensor is in.",
                        rest: "Carry it around and each room keeps its own history.") {
                    Text("居間\n寝室").font(Typeface.mincho(13)).foregroundStyle(Ink.inkSoft)
                        .multilineTextAlignment(.center)
                }
                feature(first: "A soft fūrin rings once when the air crosses your limit.", rest: nil) {
                    Text("鈴").font(Typeface.mincho(26)).foregroundStyle(Ink.inkSoft)
                }
            }

            NoteCard {
                Text(platform == .mac ? "Around the clock" : "While Kūki is open")
                    .font(Typeface.title)
                    .foregroundStyle(Ink.ink)
                BodyText(note, ink: true)
            }
        }
        .frame(maxWidth: OnboardingMetrics.maxColumn, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var note: String {
        switch platform {
        case .iPhone:
            "Apple Home shares readings only while Kūki is open on your iPhone. For an unbroken record, leave a spare iPhone or iPad in Station Mode, or let a Mac record from its menu bar."
        case .iPad:
            "Apple Home shares readings only while Kūki is open on your iPad. For an unbroken record, leave a spare iPad or iPhone in Station Mode, or let a Mac record from its menu bar."
        case .mac:
            "On this Mac, Kūki lives in the menu bar and records around the clock, even with its window closed. Look for it at the top of your screen."
        }
    }

    private func feature<Mark: View>(first: String, rest: String?, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(alignment: .top, spacing: 14) {
            mark()
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            (Text(first).foregroundStyle(Ink.ink) + Text(rest.map { " " + $0 } ?? "").foregroundStyle(Ink.inkSoft))
                .font(Typeface.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

import SwiftUI

/// 聴 — sensor → Apple Home → Kūki, what the ensō means, rooms and the
/// chime, and an honest note about when Kūki records.
struct ListenScreen: View {
    let platform: OnboardingPlatform

    var body: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.block) {
            VStack(alignment: .leading, spacing: OnboardingMetrics.titleToBody) {
                Eyebrow(kanji: "聴", word: String(localized: "Listening", comment: "Onboarding, Listen screen: eyebrow label above the title, small capitals (one short word)"))
                ScreenTitle(text: String(localized: "How Kūki hears the air", comment: "Onboarding, Listen screen: title"))
            }
            PipelineDiagram()
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 18) {
                feature(first: String(localized: "The ensō grows with CO₂.", comment: "Onboarding, Listen screen: feature, first sentence (in ink). Ensō = the Zen brush circle that shows CO₂, keep the word"),
                        rest: String(localized: "A short stroke is clear air; a nearly closed circle means open a window.", comment: "Onboarding, Listen screen: feature, second sentence (in grey); stroke = the brush stroke of the ensō")) {
                    HStack(spacing: 2) {
                        EnsoRing(fraction: 0.12, color: Ink.matcha, lineWidth: 2, animated: false).frame(width: 13, height: 13)
                        EnsoRing(fraction: 0.45, color: Ink.kincha, lineWidth: 2, animated: false).frame(width: 13, height: 13)
                        EnsoRing(fraction: 0.88, color: Ink.shu, lineWidth: 2, animated: false).frame(width: 13, height: 13)
                    }
                }
                feature(first: String(localized: "Tell Kūki which room the sensor is in.", comment: "Onboarding, Listen screen: feature, first sentence (in ink)"),
                        rest: String(localized: "Carry it around and each room keeps its own history.", comment: "Onboarding, Listen screen: feature, second sentence (in grey)")) {
                    Text(verbatim: "居間\n寝室").font(Typeface.mincho(13)).foregroundStyle(Ink.inkSoft)
                        .multilineTextAlignment(.center)
                }
                feature(first: String(localized: "A soft fūrin rings once when the air crosses your limit.", comment: "Onboarding, Listen screen: feature. Fūrin = the Japanese wind chime the app plays as its alert, keep the word; limit = CO₂ alert limit"), rest: nil) {
                    Text(verbatim: "鈴").font(Typeface.mincho(26)).foregroundStyle(Ink.inkSoft)
                }
            }

            NoteCard {
                Text(platform == .mac
                     ? String(localized: "Around the clock", comment: "Onboarding, Listen screen: card title on Mac, about when Kūki records")
                     : String(localized: "While Kūki is open", comment: "Onboarding, Listen screen: card title on iPhone and iPad, about when Kūki records"))
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
            String(localized: "Apple Home shares readings only while Kūki is open on your iPhone. For an unbroken record, leave a spare iPhone or iPad in Station Mode, or let a Mac record from its menu bar.", comment: "Onboarding, Listen screen: card body on iPhone. Station Mode = the app's always-on screen mode, same name as in Settings")
        case .iPad:
            String(localized: "Apple Home shares readings only while Kūki is open on your iPad. For an unbroken record, leave a spare iPad or iPhone in Station Mode, or let a Mac record from its menu bar.", comment: "Onboarding, Listen screen: card body on iPad. Station Mode = the app's always-on screen mode, same name as in Settings")
        case .mac:
            String(localized: "On this Mac, Kūki lives in the menu bar and records around the clock, even with its window closed. Look for it at the top of your screen.", comment: "Onboarding, Listen screen: card body on Mac")
        }
    }

    private func feature<Mark: View>(first: String, rest: String?, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(alignment: .top, spacing: 14) {
            mark()
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            Group {
                if let rest {
                    Text("\(Text(first).foregroundStyle(Ink.ink)) \(Text(rest).foregroundStyle(Ink.inkSoft))",
                         comment: "Onboarding, Listen screen: two sentences shown together, the first in ink, the second in grey. Keep both placeholders in this order; drop the space if your language doesn't put spaces between sentences.")
                } else {
                    Text(first).foregroundStyle(Ink.ink)
                }
            }
                .font(Typeface.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

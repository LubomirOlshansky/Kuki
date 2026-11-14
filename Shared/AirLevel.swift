import SwiftUI

/// CO₂ bands. Outdoor air is ~430 ppm (NOAA, 2025–26); these follow common indoor guidance
/// (and the thresholds most CO₂ monitors use).
enum CO2Level: CaseIterable {
    case clear, fine, stale, poor

    init(ppm: Double) {
        switch ppm {
        case ..<800: self = .clear
        case ..<1000: self = .fine
        case ..<1400: self = .stale
        default: self = .poor
        }
    }

    var kanji: String {
        switch self {
        case .clear: "澄"   // sumu — clear, limpid
        case .fine: "和"    // wa — calm, harmonious
        case .stale: "淀"   // yodomu — stagnant
        case .poor: "濁"    // nigoru — murky
        }
    }

    var title: String {
        switch self {
        case .clear: "Clear air"
        case .fine: "Fine"
        case .stale: "Getting stale"
        case .poor: "Stuffy"
        }
    }

    var advice: String {
        switch self {
        case .clear: "Like outside. Nothing to do."
        case .fine: "Comfortable. Air it out soon."
        case .stale: "Open a window for a few minutes."
        case .poor: "Ventilate now — open a window wide."
        }
    }

    var color: Color {
        switch self {
        case .clear: Ink.matcha
        case .fine: Ink.ink
        case .stale: Ink.kincha
        case .poor: Ink.shu
        }
    }
}

extension CO2Level {
    /// The advice for someone whose window is usually tilted open: a tilted
    /// window airs slowly, so "open a window" means "open it wide". `habit`
    /// is the raw `AiringHabit`, so Shared stays independent of the app.
    func advice(habit: String?) -> String {
        guard habit == "windowUsuallyOpen" else { return advice }
        switch self {
        case .stale: return "Open the window wide for a few minutes. Tilted, it airs slowly."
        case .poor: return "Open it wide now. A tilted window can't keep up."
        case .clear, .fine: return advice
        }
    }
}

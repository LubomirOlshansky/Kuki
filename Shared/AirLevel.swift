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
        case .clear: String(localized: "Clear air", comment: "Air level title (CO₂ under 800 ppm), shown under the ensō, in widgets and the menu bar. Keep short.")
        case .fine: String(localized: "Fine", comment: "Air level title (CO₂ 800–1000 ppm): the air is acceptable. Shown under the ensō, in widgets and the menu bar. Keep short.")
        case .stale: String(localized: "Getting stale", comment: "Air level title (CO₂ 1000–1400 ppm): indoor air becoming stale/stuffy — air quality, not food. Shown under the ensō, in widgets and the menu bar. Keep short.")
        case .poor: String(localized: "Stuffy", comment: "Air level title (CO₂ over 1400 ppm): indoor air is stuffy, ventilate now. Shown under the ensō, in widgets and the menu bar. Keep short.")
        }
    }

    var advice: String {
        switch self {
        case .clear: String(localized: "Like outside. Nothing to do.", comment: "Advice line under the air level title when CO₂ is as low as outdoor air.")
        case .fine: String(localized: "Comfortable. Air it out soon.", comment: "Advice line under the air level title when CO₂ is acceptable but rising.")
        case .stale: String(localized: "Open a window for a few minutes.", comment: "Advice line under the air level title when indoor air is getting stale.")
        case .poor: String(localized: "Ventilate now — open a window wide.", comment: "Advice line under the air level title when indoor air is stuffy.")
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
        case .stale: return String(localized: "Open the window wide for a few minutes. Tilted, it airs slowly.", comment: "Advice when indoor air is getting stale, for someone whose window is usually tilted open (a tilt-and-turn window, opened a crack at the top).")
        case .poor: return String(localized: "Open it wide now. A tilted window can't keep up.", comment: "Advice when indoor air is stuffy, for someone whose window is usually tilted open (a tilt-and-turn window). 'it' = the window.")
        case .clear, .fine: return advice
        }
    }
}

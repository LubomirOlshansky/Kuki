import SwiftUI

/// CO₂ bands. Outdoor air is ~420 ppm; these follow common indoor guidance
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
        case .poor: "Ventilate now — focus and sleep suffer."
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

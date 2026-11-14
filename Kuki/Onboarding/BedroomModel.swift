import Foundation

/// 寝 A single-zone estimate of CO₂ in a closed bedroom:
/// dC/dt = G/V − n·(C − C₀). An estimate, labelled as one in the UI.
enum BedroomModel {
    /// ppm outdoors — NOAA Mauna Loa, 2025–26 seasonal peak about 430 (S1).
    static let outdoor = 430.0
    /// m³, about 12 m² × 2.5 m.
    static let volume = 30.0
    /// h⁻¹, window shut (Bekö 2010: 500 Danish bedrooms, geometric mean 0.46).
    static let closedACH = 0.5
    /// h⁻¹, window wide open (illustrative).
    static let openACH = 15.0
    /// m³/h of CO₂ per sleeping adult = 0.0035 L/s (Persily & de Jonge 2017,
    /// adults at about 1 met: 0.0029–0.0039 L/s).
    static let perSleeper = 0.0126

    /// Steady-state rise above outdoor air, ppm.
    static func steadyRise(sleepers: Int, ach: Double) -> Double {
        guard sleepers > 0, ach > 0 else { return 0 }
        return Double(sleepers) * perSleeper / (ach * volume) * 1e6
    }

    static func ppm(sleepers: Int, hours: Double, start: Double = outdoor, ach: Double = closedACH) -> Double {
        let rise = steadyRise(sleepers: max(0, sleepers), ach: ach)
        return outdoor + rise + (start - outdoor - rise) * exp(-ach * max(0, hours))
    }

    /// Minutes until `target` is reached; nil when it never is.
    static func minutesToReach(_ target: Double, sleepers: Int, start: Double = outdoor) -> Double? {
        guard sleepers > 0 else { return nil }
        let ceiling = outdoor + steadyRise(sleepers: sleepers, ach: closedACH)
        guard target < ceiling else { return nil }
        if target <= start { return 0 }
        return -log(1 - (target - start) / (ceiling - start)) / closedACH * 60
    }

    /// The window wide open for `minutes`, the sleepers still breathing.
    static func afterAiring(from start: Double, minutes: Double, sleepers: Int) -> Double {
        ppm(sleepers: sleepers, hours: minutes / 60, start: start, ach: openACH)
    }
}

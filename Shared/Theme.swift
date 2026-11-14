import SwiftUI
import UIKit

/// Kūki's palette: washi paper and sumi ink, with three natural pigments
/// carrying meaning (matcha = clear, kincha = stale, shu = act now).
/// Every colour adapts to dark mode, where the page becomes night ink.
enum Ink {
    static let paper     = dynamic(light: 0xF3EFE6, dark: 0x121211)
    static let paperRaised = dynamic(light: 0xEBE6DB, dark: 0x1B1B19)
    static let ink       = dynamic(light: 0x22211F, dark: 0xE9E4D8)
    /// Secondary text. 68 % ink: 5.2:1 on washi, 7.3:1 at night (≥ 4.5:1 for small text);
    /// 85 % with Increase Contrast.
    static let inkSoft   = dynamic(light: 0x22211F, dark: 0xE9E4D8, alpha: 0.68, highContrastAlpha: 0.85)
    /// Decoration only (rules, tracks, redundant kanji) — never the sole carrier of text.
    static let inkFaint  = dynamic(light: 0x22211F, dark: 0xE9E4D8, alpha: 0.30, highContrastAlpha: 0.55)
    static let hairline  = dynamic(light: 0x22211F, dark: 0xE9E4D8, alpha: 0.12, highContrastAlpha: 0.30)

    static let matcha    = dynamic(light: 0x5F7D4C, dark: 0x93B27B)
    static let kincha    = dynamic(light: 0xA97A2C, dark: 0xD5A95A)
    static let shu       = dynamic(light: 0xB23B26, dark: 0xE46B50)
    static let ai        = dynamic(light: 0x2E4868, dark: 0x93ADCD)

    /// Series colours for places on charts — muted, distinguishable, never
    /// loud, and deliberately *without* meaning: matcha, kincha and shu say
    /// "clear / stale / act now" elsewhere, so a place must never wear them
    /// (shu appears on charts only as the limit line).
    static let series: [Color] = [
        dynamic(light: 0x2E4868, dark: 0x93ADCD), // ai, indigo
        dynamic(light: 0x6B5A7A, dark: 0xB4A2C4), // fuji, wisteria
        dynamic(light: 0x3F7373, dark: 0x8DBDBD), // seiji, celadon
        dynamic(light: 0x7A5B48, dark: 0xC09A82), // kogecha, burnt tea
        dynamic(light: 0x5E5D59, dark: 0xA9A8A2), // nezumi, mouse grey
    ]

    /// A colour that follows light/dark — and, through `highContrastAlpha`,
    /// the Increase Contrast setting, where the quiet greys step forward.
    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1,
                                highContrastAlpha: CGFloat? = nil) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            let a = traits.accessibilityContrast == .high ? (highContrastAlpha ?? alpha) : alpha
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: a
            )
        })
    }
}

enum Typeface {
    /// Mincho (serif) for the Japanese accents — brush-like, quiet.
    static func mincho(_ size: CGFloat) -> Font {
        .custom("HiraMinProN-W3", size: size, relativeTo: .body)
    }

    /// The big reading. Ultralight — kept only for this display size (64 pt
    /// and up) — and one step heavier with Bold Text. Monospaced digits so it
    /// never jitters.
    static func numeral(_ size: CGFloat, bold: Bool = false) -> Font {
        .system(size: size, weight: bold ? .regular : .ultraLight, design: .default).monospacedDigit()
    }

    /// Page titles: light at large-title size (HIG: avoid the thinnest
    /// weights), regular with Bold Text.
    static func pageTitle(bold: Bool = false) -> Font {
        .system(.largeTitle).weight(bold ? .regular : .light)
    }

    static let label = Font.system(.caption, design: .default).weight(.regular)
    /// Regular, not light: thin weights at small sizes lose legibility (HIG typography).
    static let body = Font.system(.body, design: .default)
    static let title = Font.system(.title3, design: .default).weight(.regular)
}

extension View {
    /// Small, letter-spaced, uppercase label — the app's only "chrome".
    func kukiLabel() -> some View {
        self.font(Typeface.label)
            .textCase(.uppercase)
            .tracking(1.6)
            .foregroundStyle(Ink.inkSoft)
    }

    func paperBackground() -> some View {
        self.background(Ink.paper.ignoresSafeArea())
    }
}

/// A thin rule, like a fold in paper.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Ink.hairline).frame(height: 0.5)
    }
}

/// Quiet press feedback: a slight sink, no flash.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

/// "Ink diffusing in water": text that changes meaning (a new level, a new
/// place) fades through a soft blur instead of cutting.
struct InkDiffuse: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 6 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.985 : 1)
    }
}

extension AnyTransition {
    static var inkDiffuse: AnyTransition {
        .modifier(active: InkDiffuse(active: true), identity: InkDiffuse(active: false))
    }
}

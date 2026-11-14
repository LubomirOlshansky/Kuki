import SwiftUI

/// Science screens: one column, or at ≥ 760 pt two — the illustration on the
/// left, the words on the right. One view tree for both, so the hero keeps its
/// identity (and never repaints) across the breakpoint.
struct ScienceColumns<Illustration: View, Words: View>: View {
    @ViewBuilder var illustration: Illustration
    @ViewBuilder var words: Words
    @Environment(\.onboardingViewport) private var viewport
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let wide = viewport.width >= OnboardingMetrics.wideBreakpoint && !dynamicTypeSize.isAccessibilitySize
        let layout = wide
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 56))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: OnboardingMetrics.block))
        layout {
            illustration
                .frame(maxWidth: wide ? .infinity : nil)
            words
                .frame(maxWidth: wide ? OnboardingMetrics.wideTextColumn : .infinity, alignment: .leading)
        }
        .frame(maxWidth: wide ? OnboardingMetrics.maxWide : OnboardingMetrics.maxColumn)
    }
}

/// Is the introduction showing its wide layout?
struct WideReader {
    static func isWide(_ viewport: CGSize, _ type: DynamicTypeSize) -> Bool {
        viewport.width >= OnboardingMetrics.wideBreakpoint && !type.isAccessibilitySize
    }
}

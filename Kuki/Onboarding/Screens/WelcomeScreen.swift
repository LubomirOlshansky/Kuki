import SwiftUI

/// 空気 — the ensō paints itself; Begin is there (and tappable) from the start.
struct WelcomeScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingViewport) private var viewport
    @State private var showRing = false
    @State private var showKanji = false
    @State private var showWords = 0
    @State private var memory = Self.freshMemory()
    @State private var fade = 1.0

    private static func freshMemory() -> EnsoPaintMemory {
        let m = EnsoPaintMemory()
        m.token = "blank" // so the first paint counts as new: one soft tap
        return m
    }

    var body: some View {
        let compact = viewport.height < OnboardingMetrics.compactHeight
        let size = compact ? min(200, viewport.width * 0.55) : min(260, viewport.width * 0.6)
        VStack(spacing: 28) {
            ZStack {
                if showRing {
                    EnsoRing(fraction: 0.86, color: Ink.ink, lineWidth: 12, paintToken: "welcome", memory: memory)
                }
                Text(verbatim: "空気")
                    .font(Typeface.mincho(40))
                    .foregroundStyle(Ink.inkSoft)
                    .opacity(showKanji ? 1 : 0)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)

            VStack(spacing: 10) {
                if showWords >= 1 {
                    ScreenTitle(text: "Kūki")
                        .transition(.inkDiffuseOrFade(reduceMotion: reduceMotion))
                }
                if showWords >= 2 {
                    Text("How fresh is the air in this room?", comment: "Onboarding, Welcome screen: subtitle under the app name")
                        .font(Typeface.title)
                        .foregroundStyle(Ink.ink)
                        .transition(.inkDiffuseOrFade(reduceMotion: reduceMotion))
                }
                if showWords >= 3 {
                    BodyText(String(localized: "A few minutes on why air matters, then we'll find your sensor.", comment: "Onboarding, Welcome screen: body line"))
                        .padding(.top, 4)
                        .transition(.inkDiffuseOrFade(reduceMotion: reduceMotion))
                }
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .frame(minHeight: 130, alignment: .top)
        }
        .frame(maxWidth: OnboardingMetrics.maxColumn)
        .frame(maxWidth: .infinity)
        .opacity(fade)
        .task { await play() }
    }

    private func play() async {
        guard !model.welcomePlayed else { finish(); return }
        model.welcomePlayed = true
        if reduceMotion {
            fade = 0
            finish()
            withAnimation(.easeOut(duration: 0.3)) { fade = 1 }
            return
        }
        model.primaryOpacity = 0.02 // not 0: a view at opacity 0 stops taking taps, and Begin works from t = 0
        try? await Task.sleep(for: .milliseconds(250))
        showRing = true
        try? await Task.sleep(for: .milliseconds(650))
        withAnimation(.easeOut(duration: 0.8)) { showKanji = true }
        try? await Task.sleep(for: .milliseconds(500))
        for i in 1...3 {
            withAnimation(.easeOut(duration: 0.6)) { showWords = i }
            try? await Task.sleep(for: .milliseconds(120))
        }
        try? await Task.sleep(for: .milliseconds(160))
        withAnimation(.easeOut(duration: 0.4)) { model.primaryOpacity = 1 }
    }

    private func finish() {
        // Drawn finished: the memory already holds this token, so no repaint.
        memory.token = "welcome"
        showRing = true
        showKanji = true
        showWords = 3
        model.primaryOpacity = 1
    }
}

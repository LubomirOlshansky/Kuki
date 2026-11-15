import SwiftUI

/// ALPSTUGA ─ Thread ─ Home hub ── Apple Home ── Kūki, with an ink dot that
/// carries a reading along the line.
struct PipelineDiagram: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.motionPaused) private var motionPaused
    @State private var width: CGFloat = 0
    @State private var arrivals = 0

    private let stops = ["ALPSTUGA", String(localized: "Home hub", comment: "Onboarding, pipeline diagram: a stop in the chain sensor → home hub → Apple Home → Kūki, small capitals (short)"), "Apple Home", "Kūki"]
    /// Narrower than this, the four stops stack: on a phone-width column the
    /// row squeezes "HomePod or Apple TV" and the labels into two lines each.
    /// iPad and the Mac window (at least 560 pt) keep the row.
    static let verticalBelow: CGFloat = 420

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize || (width > 0 && width < Self.verticalBelow) {
                vertical
            } else {
                // A physical chain read in order, sensor first; its travelling
                // dot is placed by x, so the row stays left to right in RTL.
                horizontal
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Your ALPSTUGA talks to a home hub over Thread. Apple Home passes its readings to Kūki.", comment: "Onboarding, pipeline diagram: VoiceOver description. Thread is the name of a wireless protocol, keep it."))
    }

    private var horizontal: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(stops.enumerated()), id: \.offset) { i, stop in
                    caption(stop, index: i)
                        .frame(maxWidth: .infinity)
                }
            }
            ZStack(alignment: .leading) {
                Hairline()
                if !reduceMotion {
                    TravellingDot(paused: scenePhase != .active || motionPaused) { arrivals += 1 }
                }
            }
            .frame(height: 8)
            .padding(.horizontal, 24)
            HStack(spacing: 0) {
                Text(verbatim: "Thread").font(.caption2).foregroundStyle(Ink.inkSoft)
                    .frame(maxWidth: .infinity)
                Color.clear.frame(maxWidth: .infinity)
                Color.clear.frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
        }
    }

    private var vertical: some View {
        VStack(spacing: 6) {
            ForEach(Array(stops.enumerated()), id: \.offset) { i, stop in
                caption(stop, index: i)
                if i < stops.count - 1 {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(Ink.inkFaint)
                        if i == 0 { Text(verbatim: "Thread").font(.caption2).foregroundStyle(Ink.inkSoft) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func caption(_ text: String, index: Int) -> some View {
        VStack(spacing: 4) {
            // Every caption keeps the mini ensō's slot, so the four align.
            if index != stops.count - 1 && !dynamicTypeSize.isAccessibilitySize && width >= Self.verticalBelow {
                Color.clear.frame(width: 16, height: 16)
            }
            if index == stops.count - 1 {
                EnsoRing(fraction: 0.3, color: Ink.ink, lineWidth: 2, animated: false)
                    .frame(width: 16, height: 16)
                    .keyframeAnimator(initialValue: 1.0, trigger: arrivals) { view, scale in
                        view.scaleEffect(scale)
                    } keyframes: { _ in
                        SpringKeyframe(1.06, duration: 0.15, spring: .smooth)
                        SpringKeyframe(1.0, duration: 0.15, spring: .smooth)
                    }
            }
            HStack(spacing: 4) {
                if reduceMotion && index > 0 && !dynamicTypeSize.isAccessibilitySize && width >= Self.verticalBelow {
                    Image(systemName: "chevron.forward").font(.caption2).foregroundStyle(Ink.inkFaint)
                }
                Text(text).kukiLabel().lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
            }
            if index == 1 {
                Text("HomePod or Apple TV", comment: "Onboarding, pipeline diagram: caption under Home hub; HomePod and Apple TV are product names").font(.caption2).foregroundStyle(Ink.inkSoft)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// The 4 pt dot: 1.8 s along the line, a 0.6 s rest, again.
private struct TravellingDot: View {
    var paused: Bool
    var onArrive: () -> Void
    @State private var start = Date.now
    @State private var lastLap = -1

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: paused)) { context in
                let t = context.date.timeIntervalSince(start)
                let lap = Int(t / 2.4)
                let u = t.truncatingRemainder(dividingBy: 2.4)
                let travel = min(1, u / 1.8)
                let x = travel < 0.5 ? 2 * travel * travel : 1 - pow(-2 * travel + 2, 2) / 2
                let fade = u < 0.2 ? u / 0.2 : (u > 1.6 && u < 1.8 ? (1.8 - u) / 0.2 : (u >= 1.8 ? 0 : 1))
                Circle()
                    .fill(Ink.ink)
                    .frame(width: 4, height: 4)
                    .opacity(fade)
                    .position(x: x * geo.size.width, y: geo.size.height / 2)
                    .onChange(of: lap) { _, new in if new > lastLap { lastLap = new; onArrive() } }
            }
        }
    }
}

import SwiftUI

/// 波紋 Three rings spreading from the faint ensō like a bell's sound while
/// Apple Home is asked. Driven by a clock, not repeating animations, so they
/// stop cleanly: when `active` goes false no new ring starts, and the ones
/// already spreading finish.
struct ListeningRipples: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.motionPaused) private var motionPaused
    @State private var start = Date.now
    @State private var stoppedAt: Date?

    static let cycle: Double = 2.4
    static let stagger: Double = 0.8

    var body: some View {
        Group {
            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30,
                                        paused: scenePhase != .active || motionPaused || finished(at: .now))) { context in
                    Canvas { ctx, size in
                        let t = context.date.timeIntervalSince(start)
                        let base = min(size.width, size.height) / 2
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        for ring in 0..<3 {
                            let born = Double(ring) * Self.stagger
                            guard t >= born else { continue }
                            let wave = floor((t - born) / Self.cycle)
                            let waveStart = start.addingTimeInterval(born + wave * Self.cycle)
                            if let stoppedAt, waveStart > stoppedAt { continue }
                            let u = (t - born).truncatingRemainder(dividingBy: Self.cycle) / Self.cycle
                            let eased = 1 - pow(1 - u, 2)
                            let r = base * (0.9 + 0.6 * eased) * 0.66
                            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                            ctx.stroke(Path(ellipseIn: rect), with: .color(Ink.inkFaint.opacity(0.6 * (1 - eased))),
                                       lineWidth: 1)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: active) { _, on in
            if on { start = .now; stoppedAt = nil } else { stoppedAt = .now }
        }
        .onAppear { if !active { stoppedAt = .now } }
    }

    private func finished(at now: Date) -> Bool {
        guard let stoppedAt else { return false }
        return now.timeIntervalSince(stoppedAt) > Self.cycle + 0.1
    }
}

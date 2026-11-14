import SwiftUI

/// An ensō (円相) — the single brush-stroke circle of Zen calligraphy, left
/// open where the brush lifts. Here the stroke's length follows CO₂: a short
/// arc when the air is like outdoors, closing toward a full circle as it gets
/// stale. The stroke tapers at its tail like ink running out.
///
/// `paintToken` is the one orchestrated moment: when it changes (the sensor
/// is carried to a new place) the brush repaints the circle from nothing.
/// Pass a `memory` that outlives the view and the stroke paints only when the
/// token *truly* changes — not again when a tab is reselected or the window
/// is resized. Without one it paints on every appearance.
struct EnsoRing: View {
    /// 0…1, how far around the circle the stroke reaches.
    var fraction: Double
    var color: Color
    var lineWidth: CGFloat = 10
    var paintToken: AnyHashable = 0
    var memory: EnsoPaintMemory?
    /// False for static renderings (widgets, snapshots): drawn finished, no brush.
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var painted: Double

    init(fraction: Double, color: Color, lineWidth: CGFloat = 10,
         paintToken: AnyHashable = 0, memory: EnsoPaintMemory? = nil, animated: Bool = true) {
        self.fraction = fraction
        self.color = color
        self.lineWidth = lineWidth
        self.paintToken = paintToken
        self.memory = memory
        self.animated = animated
        // Static, or already painted for this token: start finished, so nothing replays.
        _painted = State(initialValue: !animated || memory?.token == paintToken ? 1 : 0)
    }

    var body: some View {
        let reach = max(0.02, fraction) * painted
        ZStack {
            Circle()
                .stroke(Ink.hairline, lineWidth: 0.75)

            // The tapering tail: a thinner, fainter stroke under the main one.
            Circle()
                .trim(from: 0, to: reach)
                .stroke(color.opacity(0.35), style: StrokeStyle(lineWidth: lineWidth * 0.45, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Circle()
                .trim(from: min(reach, max(0, fraction * 0.12)), to: reach)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(reduceMotion || !animated ? nil : .easeInOut(duration: 1.2), value: fraction)
        .animation(animated ? .easeInOut(duration: 1.2) : nil, value: color)
        .onAppear(perform: paintIfNeeded)
        .onChange(of: paintToken) { paintIfNeeded() }
    }

    private func paintIfNeeded() {
        guard animated else { painted = 1; return }
        if let memory {
            guard memory.token != paintToken else { painted = 1; return }
            memory.token = paintToken
        }
        paint()
    }

    private func paint() {
        guard !reduceMotion else { painted = 1; return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { painted = 0 }
        // A brush accelerates off the page and slows as the ink runs out.
        withAnimation(.timingCurve(0.3, 0.0, 0.15, 1.0, duration: 1.6).delay(0.15)) {
            painted = 1
        }
    }

    /// Map ppm to stroke length: 400 ppm (outdoors) is a short stroke,
    /// 2000 ppm closes the circle (almost — an ensō is never quite closed).
    static func fraction(for ppm: Double) -> Double {
        let t = (ppm - 400) / 1600
        return min(0.94, max(0.06, t))
    }
}

/// Which token an `EnsoRing` last painted for. Owned by something that lives
/// longer than the view (the app keeps one), so state resets of the view —
/// tab switches, layout changes — don't replay the brush.
@MainActor
final class EnsoPaintMemory {
    var token: AnyHashable?
    init() {}
}

/// The air itself, made visible: faint motes drifting up inside the ensō like
/// dust in a shaft of light. Their number follows CO₂ — clear air is nearly
/// empty, stale air visibly crowds. Deterministic per index, so nothing jumps
/// when the count changes; motes simply fade in or out. Drawn at 15 fps and
/// paused whenever the scene isn't active.
struct AirMotes: View {
    var ppm: Double
    var color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    static let maxCount = 90

    static func count(for ppm: Double) -> Int {
        let t = min(1, max(0, (ppm - 400) / 1600))
        return Int((6 + t * Double(maxCount - 6)).rounded())
    }

    /// How visible mote `index` is when `count` motes are showing: fully up
    /// to the whole part, the next one partly, the rest not at all. Animating
    /// `count` therefore fades motes in and out one after another.
    static func alpha(index: Int, count: Double) -> Double {
        min(1, max(0, count - Double(index)))
    }

    var body: some View {
        let target = Double(Self.count(for: ppm))
        MoteField(count: target, color: color, still: reduceMotion, paused: reduceMotion || scenePhase != .active)
            .animation(.easeInOut(duration: 2), value: target)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The animatable half of `AirMotes`: SwiftUI interpolates `count`, so a
/// change of air fades motes rather than popping them.
private struct MoteField: View, Animatable {
    var count: Double
    var color: Color
    var still: Bool
    var paused: Bool

    var animatableData: Double {
        get { count }
        set { count = newValue }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: paused)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let radius = min(size.width, size.height) / 2
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let shown = min(AirMotes.maxCount, Int(count.rounded(.up)))
                for i in 0..<max(0, shown) {
                    let presence = AirMotes.alpha(index: i, count: count)
                    guard presence > 0 else { continue }
                    let seed = Double(i) * 12.9898
                    let r1 = fract(sin(seed) * 43758.5453)
                    let r2 = fract(sin(seed * 1.7) * 24634.6345)
                    let r3 = fract(sin(seed * 2.3) * 12345.6789)
                    // Rise slowly, each at its own pace, wrapping around.
                    let speed = 0.012 + r3 * 0.02
                    let rise = still ? 0 : time * speed
                    let v = fract(r2 - rise)              // 0 bottom … 1 top, wrapping
                    let y = (1 - v) * 2 - 1               // -1…1
                    let sway = still ? 0 : sin(time * (0.3 + r1 * 0.4) + seed) * 0.06
                    let x = (r1 * 2 - 1) * 0.92 + sway
                    // Keep inside the circle; soften toward the edge.
                    let d = sqrt(x * x + y * y)
                    guard d < 0.86 else { continue }
                    let edgeFade = min(1, (0.86 - d) / 0.25)
                    let size = 1.1 + r3 * 1.9
                    let alpha = (0.16 + r2 * 0.28) * edgeFade * presence
                    let point = CGPoint(x: center.x + x * radius, y: center.y + y * radius)
                    let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
                }
            }
        }
    }

    private func fract(_ x: Double) -> Double { x - floor(x) }
}

#Preview {
    HStack(spacing: 24) {
        ZStack { AirMotes(ppm: 500, color: Ink.ink); EnsoRing(fraction: 0.1, color: Ink.matcha) }
        ZStack { AirMotes(ppm: 1100, color: Ink.ink); EnsoRing(fraction: 0.45, color: Ink.kincha) }
        ZStack { AirMotes(ppm: 1800, color: Ink.shu); EnsoRing(fraction: 0.88, color: Ink.shu) }
    }
    .frame(height: 140)
    .padding()
    .paperBackground()
}

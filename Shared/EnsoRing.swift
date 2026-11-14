import SwiftUI

/// An ensō (円相) — the single brush-stroke circle of Zen calligraphy, left
/// open where the brush lifts. Here the stroke's length follows CO₂: a short
/// arc when the air is like outdoors, closing toward a full circle as it gets
/// stale.
///
/// Drawn as a brush, not a gauge: no track, a heavier press where the brush
/// lands, a slight hand-made wobble, and a tail that thins and breaks into
/// dry-brush streaks (kasure, 掠れ) where it lifts.
///
/// `paintToken` is the one orchestrated moment: when it changes (the sensor
/// is carried to a new place) the old stroke lifts off and the brush repaints
/// the circle from nothing. Pass a `memory` that outlives the view and the
/// stroke paints only when the token *truly* changes — not again when a tab is
/// reselected or the window is resized. Without one it paints on every
/// appearance.
struct EnsoRing: View {
    /// 0…1, how far around the circle the stroke reaches.
    var fraction: Double
    var color: Color
    var lineWidth: CGFloat = 10
    var paintToken: AnyHashable = 0
    var memory: EnsoPaintMemory?
    /// False for static renderings (widgets, snapshots): drawn finished, no brush.
    var animated = true
    /// 0 dry … 1 just painted. Wet ink reads lighter; it dries as the sensor
    /// settles into a new room.
    var wetness: Double = 0
    /// How the stroke follows a new fraction (nil = at once). The onboarding
    /// simulator drives it directly while it sweeps.
    var fractionAnimation: Animation? = .easeInOut(duration: 1.2)
    /// How the pigment crossfades to a new colour.
    var colorAnimation: Animation? = .easeInOut(duration: 1.2)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var painted: Double
    /// True for the moment the old stroke is lifting off before a repaint.
    @State private var lifted = false
    /// Bumped when the brush lands for a new place — the haptic's trigger.
    @State private var landings = 0

    init(fraction: Double, color: Color, lineWidth: CGFloat = 10,
         paintToken: AnyHashable = 0, memory: EnsoPaintMemory? = nil, animated: Bool = true,
         wetness: Double = 0,
         fractionAnimation: Animation? = .easeInOut(duration: 1.2),
         colorAnimation: Animation? = .easeInOut(duration: 1.2)) {
        self.fractionAnimation = fractionAnimation
        self.colorAnimation = colorAnimation
        self.fraction = fraction
        self.color = color
        self.lineWidth = lineWidth
        self.paintToken = paintToken
        self.memory = memory
        self.animated = animated
        self.wetness = wetness
        // Static, or already painted for this token: start finished, so nothing replays.
        _painted = State(initialValue: !animated || memory?.token == paintToken ? 1 : 0)
    }

    var body: some View {
        let reach = max(0.02, fraction) * painted
        ZStack {
            // A ghost of the whole circle, half a point at a whisper of ink —
            // just enough that a short stroke in clear air still reads as the
            // start of a circle. Not a track: no width, no caps, no colour.
            if lineWidth >= EnsoGeometry.kasureMinLineWidth {
                Circle()
                    .stroke(Ink.hairline, lineWidth: 0.5)
                    .opacity(0.6)
                    .padding(lineWidth * 0.1)
            }
            ZStack {
                EnsoBrush(reach: reach, lineWidth: lineWidth)
                    .fill(color)
                if lineWidth >= EnsoGeometry.kasureMinLineWidth {
                    EnsoKasure(reach: reach, lineWidth: lineWidth)
                        .stroke(color.opacity(0.55), style: EnsoGeometry.kasureStyle(lineWidth: lineWidth))
                }
            }
            .opacity((lifted ? 0 : 1) * (1 - 0.45 * min(1, max(0, wetness))))
        }
        .animation(reduceMotion || !animated ? nil : fractionAnimation, value: fraction)
        .animation(animated ? colorAnimation : nil, value: color)
        .animation(animated ? .easeInOut(duration: 1.5) : nil, value: wetness)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: landings)
        .onAppear(perform: paintIfNeeded)
        .onChange(of: paintToken) { paintIfNeeded() }
    }

    private func paintIfNeeded() {
        guard animated else { painted = 1; return }
        var newPlace = false
        if let memory {
            guard memory.token != paintToken else { painted = 1; return }
            newPlace = memory.token != nil
            memory.token = paintToken
        }
        paint(newPlace: newPlace)
    }

    /// The choreography: the old stroke lifts (0.2 s), the brush lands — one
    /// soft tap — and paints the new circle (1.6 s), accelerating off the page
    /// and slowing as the ink runs out. Under 2 s in all.
    private func paint(newPlace: Bool) {
        guard !reduceMotion else {
            painted = 1
            if newPlace { landings += 1 }
            return
        }
        if painted > 0.01 {
            withAnimation(.easeIn(duration: 0.2)) {
                lifted = true
            } completion: {
                brushDown(newPlace: newPlace)
            }
        } else {
            brushDown(newPlace: newPlace)
        }
    }

    private func brushDown(newPlace: Bool) {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            painted = 0
            lifted = false
        }
        if newPlace { landings += 1 }
        withAnimation(.timingCurve(0.3, 0.0, 0.15, 1.0, duration: 1.6)) {
            painted = 1
        }
    }

    /// Map ppm to stroke length: 400 ppm (outdoors) is a short stroke,
    /// 2000 ppm closes the circle (almost — an ensō is never quite closed).
    nonisolated static func fraction(for ppm: Double) -> Double {
        let t = (ppm - 400) / 1600
        return min(0.94, max(0.10, t))
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

// MARK: - Brush geometry

/// The shape of the stroke, kept pure so it can be tested and reused at any
/// size — from the 18 pt Dynamic Island mark to the 440 pt hero.
enum EnsoGeometry {
    /// The brush lands a little before twelve o'clock, as a hand would.
    static let startAngle = -Double.pi / 2 - 0.17
    /// Below this, dry-brush hairs would be thinner than a pixel.
    static let kasureMinLineWidth: CGFloat = 4

    /// Radius of the stroke's centre line inside `rect`.
    static func radius(in rect: CGRect, lineWidth: CGFloat) -> Double {
        Double(min(rect.width, rect.height)) / 2 - Double(lineWidth) * 0.1
    }

    /// The circle is drawn by hand: a barely-there wobble in its radius.
    static func radius(_ r: Double, at angle: Double) -> Double {
        r * (1 + 0.008 * sin(2 * angle + 0.6))
    }

    /// Stroke width at distance `d` (points) along a stroke `length` long:
    /// a heavier press where the brush lands, a slight living variation, and
    /// a tail that thins toward the lift.
    static func width(at d: Double, length: Double, lineWidth w: Double) -> Double {
        guard length > 0, w > 0 else { return 0 }
        // 0 for a short dab … 1 for a long sweep: short strokes get a gentler
        // landing and a longer, softer taper so they read as one clean
        // gesture instead of a blob with a wedge.
        let sweep = min(1, length / (w * 14))
        let press = min(length * 0.3, w * 2.8)
        let taper = min(length * (0.7 - 0.2 * sweep), w * 7)
        var k = 1.0
        if press > 0, d < press {
            let u = d / press
            k += (0.06 + 0.10 * sweep) * (1 - u * u * (3 - 2 * u))
        }
        let tailStart = length - taper
        if taper > 0, d > tailStart {
            let u = min(1, (d - tailStart) / taper)
            k *= 1 - 0.86 * pow(u, 1.35 + 0.6 * (1 - sweep))
        }
        k *= 1 + 0.045 * sin(d / w * 0.85 + 1.3)
        return w * k
    }

    /// Dry-brush hairs: radial offset (× line width), where each starts back
    /// from the tip (× taper length) and how far past the tip it trails
    /// (× line width).
    static let hairs: [(offset: Double, start: Double, overrun: Double)] = [
        (-0.30, 1.25, -0.3), (0.04, 0.9, 0.6), (0.33, 1.1, 0.1),
    ]

    static func kasureStyle(lineWidth w: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: max(0.5, w * 0.11), lineCap: .round,
                    dash: [w * 2.4, w * 0.7, w * 1.1, w * 1.6])
    }

    static func point(center: CGPoint, radius: Double, angle: Double) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }
}

/// The body of the stroke as one filled outline: a round landing, the outer
/// edge forward, a narrow tip, the inner edge back.
struct EnsoBrush: Shape {
    var reach: Double
    var lineWidth: CGFloat

    var animatableData: Double {
        get { reach }
        set { reach = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = Double(lineWidth)
        let r = EnsoGeometry.radius(in: rect, lineWidth: lineWidth)
        let span = max(0, min(1, reach)) * 2 * .pi
        guard span > 0, r > 0 else { return path }
        let length = span * r
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let steps = max(8, Int(span / (2 * .pi) * 180))

        var outer: [CGPoint] = []
        var inner: [CGPoint] = []
        outer.reserveCapacity(steps + 1)
        inner.reserveCapacity(steps + 1)
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let angle = EnsoGeometry.startAngle + span * t
            let rr = EnsoGeometry.radius(r, at: angle)
            let half = EnsoGeometry.width(at: length * t, length: length, lineWidth: w) / 2
            outer.append(EnsoGeometry.point(center: center, radius: rr + half, angle: angle))
            inner.append(EnsoGeometry.point(center: center, radius: max(0, rr - half), angle: angle))
        }

        // The landing: a blunt, flattened half-ellipse behind the start
        // (inner → back → outer) — a brush set down, not a ball.
        let a0 = EnsoGeometry.startAngle
        let c0 = EnsoGeometry.point(center: center, radius: EnsoGeometry.radius(r, at: a0), angle: a0)
        let h0 = EnsoGeometry.width(at: 0, length: length, lineWidth: w) / 2
        let tangent = CGPoint(x: -sin(a0), y: cos(a0))
        let normal = CGPoint(x: cos(a0), y: sin(a0))
        path.move(to: inner[0])
        for k in 1...10 {
            let phi = -Double.pi / 2 + Double.pi * Double(k) / 10
            let back = h0 * 0.55 * cos(phi), side = h0 * sin(phi)
            path.addLine(to: CGPoint(x: c0.x - tangent.x * back + normal.x * side,
                                     y: c0.y - tangent.y * back + normal.y * side))
        }
        for p in outer.dropFirst() { path.addLine(to: p) }
        for p in inner.reversed() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }
}

/// The dry-brush streaks at the tail, where the bristles part as the ink
/// runs out.
struct EnsoKasure: Shape {
    var reach: Double
    var lineWidth: CGFloat

    var animatableData: Double {
        get { reach }
        set { reach = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = Double(lineWidth)
        let r = EnsoGeometry.radius(in: rect, lineWidth: lineWidth)
        let span = max(0, min(1, reach)) * 2 * .pi
        let length = span * r
        // Too short a stroke has no tail to split.
        // Dry-brush hairs belong to a long sweep; on a short dab they read as
        // scratches.
        guard r > 0, length > w * 12 else { return path }
        let taper = min(length * 0.5, w * 7)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for hair in EnsoGeometry.hairs {
            let from = max(0, length - taper * hair.start)
            let to = length + w * hair.overrun
            guard to > from else { continue }
            let steps = max(4, Int((to - from) / max(1, w * 0.5)))
            for i in 0...steps {
                let d = from + (to - from) * Double(i) / Double(steps)
                let angle = EnsoGeometry.startAngle + d / r
                let p = EnsoGeometry.point(center: center,
                                           radius: EnsoGeometry.radius(r, at: angle) + hair.offset * w,
                                           angle: angle)
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
        }
        return path
    }
}

// MARK: - Motion pause

/// True while the window showing a view can't be seen — hidden, minimised or
/// covered. On the Mac a menu-bar app stays `.active` (scenePhase) even then,
/// so the app sets this from the window's occlusion and every continuous
/// animation stops drawing. Defaults to false (widgets, previews).
private struct MotionPausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var motionPaused: Bool {
        get { self[MotionPausedKey.self] }
        set { self[MotionPausedKey.self] = newValue }
    }
}

// MARK: - Air motes

/// The air itself, made visible: faint motes drifting up inside the ensō like
/// dust in a shaft of light. Clear air (under 800 ppm) has none — their
/// absence is the message; from there their number grows with CO₂. They keep
/// out of the reading in the middle, so they never sit on the numbers.
/// Deterministic per index, so nothing jumps when the count changes; motes
/// simply fade in or out. Drawn at 15 fps and paused whenever the scene isn't
/// active or its window can't be seen (`motionPaused`).
struct AirMotes: View {
    var ppm: Double
    var color: Color
    /// 0…1 — scales the count; animate it up to let a new room's air "arrive".
    var reveal: Double = 1
    /// Half-size of the clear zone around the reading, in units of the field's
    /// radius.
    var exclusion = CGSize(width: 0.68, height: 0.40)
    /// 0 still air … 1 a gust through an open window: the motes are carried
    /// sideways and out of the circle. Animatable, so it can ramp.
    var wind: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.motionPaused) private var motionPaused
    /// When the current gust began (reference time), so motes accelerate from
    /// where they are instead of jumping.
    @State private var gustStart: Double?

    nonisolated static let maxCount = 90
    /// Below this the air is clear, and the field is empty.
    nonisolated static let threshold = 800.0

    nonisolated static func count(for ppm: Double) -> Int {
        guard ppm >= threshold else { return 0 }
        let t = min(1, max(0, (ppm - threshold) / 1200))
        return Int((10 + t * Double(maxCount - 10)).rounded())
    }

    /// How visible mote `index` is when `count` motes are showing: fully up
    /// to the whole part, the next one partly, the rest not at all. Animating
    /// `count` therefore fades motes in and out one after another.
    nonisolated static func alpha(index: Int, count: Double) -> Double {
        min(1, max(0, count - Double(index)))
    }

    /// 0 inside the clear zone around the reading, rising to 1 just outside
    /// it. `x`, `y` are in units of the field's radius, centred.
    nonisolated static func exclusionFade(x: Double, y: Double, zone: CGSize) -> Double {
        let dx = max(0, abs(x) - Double(zone.width))
        let dy = max(0, abs(y) - Double(zone.height))
        return min(1, max(dx, dy) / 0.12)
    }

    /// The clear zone for a reading with `digits` digits.
    nonisolated static func exclusion(digits: Int) -> CGSize {
        CGSize(width: min(0.86, 0.2 + 0.16 * Double(max(1, digits))), height: 0.40)
    }

    var body: some View {
        let base = Double(Self.count(for: ppm))
        let shown = base * min(1, max(0, reveal))
        MoteField(count: shown, color: color, zone: exclusion,
                  still: reduceMotion, paused: reduceMotion || scenePhase != .active || motionPaused,
                  wind: reduceMotion ? 0 : wind, gustStart: gustStart ?? 0)
            .animation(.easeInOut(duration: 2), value: base)
            .animation(reveal == 0 ? nil : .easeInOut(duration: 2), value: reveal)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: wind > 0) { _, gusting in
                gustStart = gusting ? Date.now.timeIntervalSinceReferenceDate : nil
            }
    }
}

/// The animatable half of `AirMotes`: SwiftUI interpolates `count`, so a
/// change of air fades motes rather than popping them.
private struct MoteField: View, Animatable {
    var count: Double
    var color: Color
    var zone: CGSize
    var still: Bool
    var paused: Bool
    var wind: Double = 0
    var gustStart: Double = 0

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(count, wind) }
        set { count = newValue.first; wind = newValue.second }
    }

    var body: some View {
        // Clear air: nothing to draw, so nothing ticks either.
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: paused || count <= 0)) { timeline in
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
                    // A gust: each mote is carried sideways, faster the longer it blows.
                    let gust = wind > 0 ? wind * wind * 1.4 * max(0, time - gustStart) * (0.6 + r1 * 0.8) : 0
                    let x = (r1 * 2 - 1) * 0.92 + sway + gust
                    // Keep inside the circle; soften toward the edge.
                    let d = sqrt(x * x + y * y)
                    guard d < 0.86 else { continue }
                    let clear = AirMotes.exclusionFade(x: x, y: y, zone: zone)
                    guard clear > 0 else { continue }
                    let edgeFade = min(1, (0.86 - d) / 0.25)
                    let size = 1.6 + r3 * 1.4
                    let alpha = (0.30 + r2 * 0.25) * edgeFade * presence * clear
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
    VStack(spacing: 24) {
        HStack(spacing: 24) {
            ZStack { AirMotes(ppm: 500, color: Ink.ink); EnsoRing(fraction: 0.1, color: Ink.matcha, lineWidth: 9) }
            ZStack { AirMotes(ppm: 1100, color: Ink.ink); EnsoRing(fraction: 0.45, color: Ink.kincha, lineWidth: 9) }
            ZStack { AirMotes(ppm: 1800, color: Ink.shu); EnsoRing(fraction: 0.88, color: Ink.shu, lineWidth: 9) }
        }
        .frame(height: 140)
        HStack(spacing: 18) {
            EnsoRing(fraction: 0.15, color: Ink.matcha, lineWidth: 2.5, animated: false).frame(width: 18, height: 18)
            EnsoRing(fraction: 0.3, color: Ink.ink, lineWidth: 4, animated: false).frame(width: 44, height: 44)
            EnsoRing(fraction: 0.5, color: Ink.kincha, lineWidth: 5, animated: false).frame(width: 70, height: 70)
            EnsoRing(fraction: 0.2, color: Ink.matcha, lineWidth: 6, animated: false).frame(width: 118, height: 118)
        }
    }
    .padding()
    .paperBackground()
}

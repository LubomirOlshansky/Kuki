import Accessibility
import HomeKit
import SwiftUI
import UIKit

/// 家 — the primer, then Apple Home's answer: listening, slow, found, several,
/// none, denied. One screen whose content follows `HomeConnectionState`; the
/// ensō stays in place and becomes the reading when a sensor is found.
struct AppleHomeScreen: View {
    @Bindable var model: OnboardingModel
    let platform: OnboardingPlatform
    @Environment(Recorder.self) private var recorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingViewport) private var viewport
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var ensoScaled: CGFloat = 220
    @ScaledMetric(relativeTo: .largeTitle) private var numeralScaled: CGFloat = 64
    @Environment(\.legibilityWeight) private var legibilityWeight

    @State private var memory = Self.listeningMemory()
    @State private var moteReveal = 0.0
    @State private var announcedKind: String?

    private static func listeningMemory() -> EnsoPaintMemory {
        let m = EnsoPaintMemory()
        m.token = "listening"
        return m
    }

    var body: some View {
        let state = model.homeState(recorder)
        VStack(alignment: .leading, spacing: OnboardingMetrics.block) {
            Eyebrow(kanji: "家", word: "Apple Home")
            illustration(state)
                .frame(maxWidth: .infinity)
            content(state)
                .id(state.kind + (state.sensor?.id.uuidString ?? ""))
                .transition(.inkDiffuseOrFade(reduceMotion: reduceMotion))
        }
        .animation(.easeInOut(duration: 0.5), value: state.kind)
        .frame(maxWidth: OnboardingMetrics.maxColumn, alignment: .leading)
        .frame(maxWidth: .infinity)
        .onChange(of: state.kind, initial: true) { _, _ in stateChanged(state) }
        .onChange(of: recorder.homeKit.status) { model.noteFound(recorder) }
        .onChange(of: recorder.homeKit.sensors) { model.noteFound(recorder) }
    }

    // MARK: Illustration

    private var heroSize: CGFloat {
        HeroSize.science(scaled: ensoScaled, viewport: viewport, column: min(viewport.width, OnboardingMetrics.maxColumn),
                         accessibility: dynamicTypeSize.isAccessibilitySize)
    }

    @ViewBuilder
    private func illustration(_ state: HomeConnectionState) -> some View {
        let reading = Self.reading(state)
        let size = reading == nil ? 120 : heroSize
        ZStack {
            ListeningRipples(active: state == .waiting || state == .slow || isFoundWaiting(state))
                .frame(width: 120 * 1.6, height: 120 * 1.6)
            if let reading, let ppm = reading.ppm, reading.fresh {
                AirMotes(ppm: ppm, color: CO2Level(ppm: ppm) == .poor ? Ink.shu : Ink.ink, reveal: moteReveal,
                         exclusion: AirMotes.exclusion(digits: Metric.co2.format(ppm).count))
                    .frame(width: size * 232 / 256, height: size * 232 / 256)
            }
            EnsoRing(fraction: reading?.ppm.map { EnsoRing.fraction(for: $0) } ?? 0.08,
                     color: reading.map { r in r.fresh && r.ppm != nil ? CO2Level(ppm: r.ppm!).color : Ink.inkFaint } ?? Ink.inkFaint,
                     lineWidth: reading == nil ? 6 : 9,
                     paintToken: AnyHashable(reading?.token ?? "listening"), memory: memory)
                .frame(width: size, height: size)
            if let reading, let ppm = reading.ppm {
                VStack(spacing: 2) {
                    Text(Metric.co2.format(ppm))
                        .font(Typeface.numeral(min(max(numeralScaled, size * 0.28), size * 0.32),
                                               bold: legibilityWeight == .bold))
                        .foregroundStyle(reading.fresh ? Ink.ink : Ink.inkSoft)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .contentTransition(.numericText(value: ppm))
                    Text("ppm CO₂").kukiLabel()
                }
                .frame(maxWidth: size * 0.72)
                .transition(.inkDiffuseOrFade(reduceMotion: reduceMotion))
            }
        }
        // The ripples may spread past this frame; the ensō area keeps its place.
        .frame(width: max(size, 192), height: reading == nil ? 150 : size)
        .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: size)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(reading?.ppm == nil)
        .accessibilityLabel("CO₂")
        .accessibilityValue(reading?.ppm.map { "\(Metric.co2.spoken($0)), \(CO2Level(ppm: $0).title)" } ?? "")
    }

    private struct Reading { let ppm: Double?; let fresh: Bool; let token: String }

    private static func reading(_ state: HomeConnectionState) -> Reading? {
        switch state {
        case .found(let s, let ppm, let fresh):
            guard ppm != nil || fresh else { return nil }
            return Reading(ppm: ppm, fresh: fresh, token: s.id.uuidString)
        default:
            return nil
        }
    }

    private func isFoundWaiting(_ state: HomeConnectionState) -> Bool {
        if case .foundWaiting = state { return true }
        return false
    }

    // MARK: Words

    @ViewBuilder
    private func content(_ state: HomeConnectionState) -> some View {
        let device = OnboardingCopy.device(platform)
        switch state {
        case .notRequested:
            block(title: "Kūki reads your sensor through Apple Home.") {
                BodyText("Next, your \(device) will ask whether Kūki may use your Home data.", ink: true)
                BodyText("Kūki only reads air sensors: CO₂, temperature, humidity and particles. It never changes anything in your home, and readings stay on your devices.")
            }
        case .waiting:
            block(title: "Listening for Apple Home…") {
                BodyText("This usually takes a few seconds.")
            }
        case .slow:
            block(title: "Apple Home is taking its time") {
                BodyText("It can take up to a minute after your \(device) wakes. Check that you're signed in to iCloud and that the Home app shows your home.")
            }
        case .found(let s, let ppm, let fresh):
            if fresh || ppm == nil {
                found(s, ppm: ppm)
            } else {
                block(title: "Found \(s.name)") {
                    sensorLines(s)
                    BodyText("Last reported \(lastHeardText(s)). Apple Home hasn't sent a new reading yet. It often arrives within a minute.")
                }
            }
        case .foundWaiting(let s):
            block(title: "Found \(s.name)") {
                sensorLines(s)
                BodyText("Waiting for its first reading…")
            }
        case .unreachable(let s):
            block(title: "\(s.name) is out of reach") {
                BodyText("Apple Home can't reach it right now. Check that it's plugged in and near your home hub.")
            }
        case .several(let sensors):
            block(title: "Which sensor is yours?") {
                BodyText("Kūki follows one sensor at a time. You can switch in Settings.")
                VStack(spacing: 10) {
                    ForEach(sensors) { s in sensorRow(s) }
                }
                .padding(.top, 6)
            }
        case .noHome:
            block(title: "Apple Home has no home yet") {
                BodyText("Set up your home in the Home app first, then add the sensor. Kūki will notice it here.")
            }
        case .noSensor:
            block(title: "No air sensor in Apple Home yet") {
                VStack(alignment: .leading, spacing: 14) {
                    guideRow("一", "Plug in your ALPSTUGA. It's ready to pair once it powers up.")
                    guideRow("二", platform == .mac
                             ? "Add it with the Home app on your iPhone or iPad. This Mac will see it a moment later."
                             : "In the Home app, tap + › Add Accessory, then scan the Matter code that came with the sensor.")
                    guideRow("三", "Thread needs a home hub nearby: a HomePod mini, a HomePod (2nd generation), or an Apple TV 4K with Ethernet.")
                }
                Text("Kūki will notice it as soon as it's added.")
                    .font(.footnote)
                    .foregroundStyle(Ink.inkSoft)
            }
        case .denied:
            block(title: "Kūki can't see Apple Home") {
                BodyText(EmptySensorView.homeAccessMessage)
            }
        }
    }

    private func block<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenTitle(text: title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func found(_ s: SensorInfo, ppm: Double?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenTitle(text: "There it is.")
            sensorLines(s)
            if let ppm {
                let level = CO2Level(ppm: ppm)
                HStack(spacing: 10) {
                    Text(level.kanji).font(Typeface.mincho(22)).foregroundStyle(level.color).accessibilityHidden(true)
                    Text(level.title).font(Typeface.title).foregroundStyle(Ink.ink)
                }
                BodyText(s.room.isEmpty ? "That's the air around your sensor right now." : "That's the air in \(s.room) right now.", ink: true)
            } else {
                BodyText("This sensor doesn't report CO₂, so Kūki will show its other values.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func sensorLines(_ s: SensorInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.name).font(Typeface.title).foregroundStyle(Ink.ink)
            let where_ = OnboardingCopy.roomAndHome(room: s.room, home: s.home)
            if !where_.isEmpty { BodyText(where_) }
        }
        .accessibilityElement(children: .combine)
    }

    private func sensorRow(_ s: SensorInfo) -> some View {
        let snap = recorder.homeKit.snapshots[s.id]
        let fresh = snap?.freshValue(.co2, now: model.clock)
        let ppm = fresh ?? snap?.co2
        var subtitle = OnboardingCopy.roomAndHome(room: s.room, home: s.home)
        if snap?.co2 == nil {
            subtitle += subtitle.isEmpty ? "No CO₂ reading" : " · No CO₂ reading"
        } else if let fresh {
            subtitle += " · \(Metric.co2.format(fresh)) ppm"
        }
        let selected = (model.stagedSensor ?? recorder.homeKit.sensors.first?.id) == s.id
        return ChoiceRow(title: s.name, subtitle: subtitle, selected: selected, action: { model.stagedSensor = s.id }) {
            Group {
                if let ppm {
                    EnsoRing(fraction: EnsoRing.fraction(for: ppm), color: fresh != nil ? CO2Level(ppm: ppm).color : Ink.inkFaint,
                             lineWidth: 3, animated: false)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "circle.dotted").font(.title3).foregroundStyle(Ink.inkFaint)
                }
            }
            .frame(width: 30)
            .accessibilityHidden(true)
        }
    }

    private func guideRow(_ numeral: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(numeral).font(Typeface.mincho(22)).foregroundStyle(Ink.inkSoft).frame(width: 28).accessibilityHidden(true)
            BodyText(text, ink: true)
        }
    }

    private func lastHeardText(_ s: SensorInfo) -> String {
        guard let heard = recorder.homeKit.snapshots[s.id]?.lastHeard else { return "earlier" }
        return heard.formatted(date: .omitted, time: .shortened)
    }

    // MARK: Changes

    private func stateChanged(_ state: HomeConnectionState) {
        model.reportHome(state, recorder: recorder)
        guard announcedKind != state.kind else { return }
        announcedKind = state.kind
        let text: String?
        switch state {
        case .waiting: text = "Looking for Apple Home."
        case .slow: text = "Apple Home is taking its time."
        case .found(let s, let ppm, true):
            let room = s.room.isEmpty ? "" : " in \(s.room)"
            text = ppm.map { "Found \(s.name)\(room). \(Metric.co2.spoken($0)), \(CO2Level(ppm: $0).title)." } ?? "Found \(s.name)\(room)."
            revealMotes()
        case .noSensor: text = "No air sensor found in Apple Home."
        case .denied: text = "Kūki can't see Apple Home."
        default: text = nil
        }
        if let text { AccessibilityNotification.Announcement(text).post() }
    }

    private func revealMotes() {
        guard !reduceMotion else { moteReveal = 1; return }
        moteReveal = 0
        Task {
            try? await Task.sleep(for: .milliseconds(1800))
            moteReveal = 1
        }
    }
}

/// The bottom-bar actions for each Apple Home state — shared by the
/// introduction and the "Connect Apple Home" sheet.
@MainActor
enum AppleHomeActions {
    static func actions(_ state: HomeConnectionState, model: OnboardingModel, recorder: Recorder,
                        platform: OnboardingPlatform, openURL: OpenURLAction,
                        done: @escaping () -> Void, tryDemo: @escaping () -> Void)
        -> (primary: OnboardingAction?, secondary: [OnboardingAction]) {
        // A replay that's already on Apple Home offers no way into the demo.
        let demo = model.offersDemo(recorder) ? [OnboardingAction(title: "Try the demo", run: tryDemo)] : []
        let check = OnboardingAction(title: "Check again") { model.checkAgain(recorder) }
        let doneTitle = model.mode == .sheet ? "Done" : "Continue"
        let home = URL(string: "com.apple.home://")!
        let openHome = OnboardingAction(title: "Open Home app") {
            openURL(home) { accepted in if !accepted { model.homeAppFailed = true } }
        }
        switch state {
        case .notRequested:
            return (OnboardingAction(title: "Continue") { model.connect(recorder) }, [])
        case .waiting:
            return (nil, [])
        case .slow:
            return (check, demo)
        case .found(_, let ppm, let fresh):
            if !fresh && ppm != nil { return (OnboardingAction(title: doneTitle, run: done), [check]) }
            return (OnboardingAction(title: doneTitle, run: done), [])
        case .foundWaiting:
            return (OnboardingAction(title: doneTitle, run: done), [])
        case .unreachable:
            return (OnboardingAction(title: doneTitle, run: done), [check])
        case .several(let sensors):
            return (OnboardingAction(title: "Continue") {
                let id = model.stagedSensor ?? sensors.first?.id
                model.chosenSensor = id
                recorder.selectedSensorID = id
                model.foundAt = .now
            }, [])
        case .noHome:
            if model.canOpenHomeApp && !model.homeAppFailed { return (openHome, [check] + demo) }
            return (check, demo)
        case .noSensor:
            #if !targetEnvironment(macCatalyst)
            if !model.addAccessoryFailed {
                let add = OnboardingAction(title: "Add Accessory…") {
                    Task {
                        do { try await recorder.homeKit.addAccessory() } catch {
                            // A cancelled sheet is a choice, not a failure.
                            if (error as? HMError)?.code != .operationCancelled { model.addAccessoryFailed = true }
                        }
                    }
                }
                return (add, [check] + demo)
            }
            #endif
            if model.canOpenHomeApp && !model.homeAppFailed { return (openHome, [check] + demo) }
            return (check, demo)
        case .denied:
            #if !targetEnvironment(macCatalyst)
            if let settings = URL(string: UIApplication.openSettingsURLString) {
                return (OnboardingAction(title: "Open Settings") { openURL(settings) }, demo)
            }
            #endif
            return (nil, demo)
        }
    }
}

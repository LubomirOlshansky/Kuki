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
                    Text(verbatim: "ppm CO₂").kukiLabel()
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
        .accessibilityLabel(Text(verbatim: "CO₂"))
        .accessibilityValue(reading?.ppm.map { String(localized: "\(Metric.co2.spoken($0)), \(CO2Level(ppm: $0).title)", comment: "VoiceOver value of a CO₂ reading in the onboarding: the spoken reading, then the air level name (e.g. Getting stale)") } ?? "")
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
            block(title: String(localized: "Kūki reads your sensor through Apple Home.", comment: "Onboarding, Apple Home screen: title before asking for Home access")) {
                BodyText(String(localized: "Next, your \(device) will ask whether Kūki may use your Home data.", comment: "Onboarding, Apple Home screen: the placeholder is iPhone, iPad or Mac"), ink: true)
                BodyText(String(localized: "Kūki only reads air sensors: CO₂, temperature, humidity and particles. It never changes anything in your home, and readings stay on your devices.", comment: "Onboarding, Apple Home screen: body before asking for Home access"))
            }
        case .waiting:
            block(title: String(localized: "Listening for Apple Home…", comment: "Onboarding, Apple Home screen: title while waiting for Apple Home to answer")) {
                BodyText(String(localized: "This usually takes a few seconds.", comment: "Onboarding, Apple Home screen: body while waiting"))
            }
        case .slow:
            block(title: String(localized: "Apple Home is taking its time", comment: "Onboarding, Apple Home screen: title when Apple Home is slow to answer")) {
                BodyText(String(localized: "It can take up to a minute after your \(device) wakes. Check that you're signed in to iCloud and that the Home app shows your home.", comment: "Onboarding, Apple Home screen: body when slow; the placeholder is iPhone, iPad or Mac"))
            }
        case .found(let s, let ppm, let fresh):
            if fresh || ppm == nil {
                found(s, ppm: ppm)
            } else {
                block(title: foundTitle(s)) {
                    sensorLines(s)
                    BodyText(lastReportedText(s))
                }
            }
        case .foundWaiting(let s):
            block(title: foundTitle(s)) {
                sensorLines(s)
                BodyText(String(localized: "Waiting for its first reading…", comment: "Onboarding, Apple Home screen: body after a sensor was found but has not reported yet"))
            }
        case .unreachable(let s):
            block(title: String(localized: "\(s.name) is out of reach", comment: "Onboarding, Apple Home screen: title; the placeholder is the sensor's name, e.g. ALPSTUGA")) {
                BodyText(String(localized: "Apple Home can't reach it right now. Check that it's plugged in and near your home hub.", comment: "Onboarding, Apple Home screen: body when the sensor is unreachable"))
            }
        case .several(let sensors):
            block(title: String(localized: "Which sensor is yours?", comment: "Onboarding, Apple Home screen: title when several sensors were found")) {
                BodyText(String(localized: "Kūki follows one sensor at a time. You can switch in Settings.", comment: "Onboarding, Apple Home screen: body when several sensors were found"))
                VStack(spacing: 10) {
                    ForEach(sensors) { s in sensorRow(s) }
                }
                .padding(.top, 6)
            }
        case .noHome:
            block(title: String(localized: "Apple Home has no home yet", comment: "Onboarding, Apple Home screen: title when Apple Home has no home set up")) {
                BodyText(String(localized: "Set up your home in the Home app first, then add the sensor. Kūki will notice it here.", comment: "Onboarding, Apple Home screen: body when there is no home"))
            }
        case .noSensor:
            block(title: String(localized: "No air sensor in Apple Home yet", comment: "Onboarding, Apple Home screen: title when no sensor is in Apple Home")) {
                VStack(alignment: .leading, spacing: 14) {
                    guideRow("一", String(localized: "Plug in your ALPSTUGA. It's ready to pair once it powers up.", comment: "Onboarding, Apple Home screen: setup step 1"))
                    guideRow("二", platform == .mac
                             ? String(localized: "Add it with the Home app on your iPhone or iPad. This Mac will see it a moment later.", comment: "Onboarding, Apple Home screen: setup step 2 on Mac")
                             : String(localized: "In the Home app, tap + › Add Accessory, then scan the Matter code that came with the sensor.", comment: "Onboarding, Apple Home screen: setup step 2. Add Accessory must match the Home app's own menu item in your language; Matter is a standard's name"))
                    guideRow("三", String(localized: "Thread needs a home hub nearby: a HomePod mini, a HomePod (2nd generation), or an Apple TV 4K with Ethernet.", comment: "Onboarding, Apple Home screen: setup step 3. Thread is a wireless protocol; HomePod and Apple TV are product names"))
                }
                Text("Kūki will notice it as soon as it's added.", comment: "Onboarding, Apple Home screen: footnote under the setup steps")
                    .font(.footnote)
                    .foregroundStyle(Ink.inkSoft)
            }
        case .denied:
            block(title: String(localized: "Kūki can't see Apple Home", comment: "Onboarding, Apple Home screen: title when Home access was denied")) {
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
            ScreenTitle(text: String(localized: "There it is.", comment: "Onboarding, Apple Home screen: title when the sensor was found with a reading"))
            sensorLines(s)
            if let ppm {
                let level = CO2Level(ppm: ppm)
                HStack(spacing: 10) {
                    Text(level.kanji).font(Typeface.mincho(22)).foregroundStyle(level.color).accessibilityHidden(true)
                    Text(level.title).font(Typeface.title).foregroundStyle(Ink.ink)
                }
                BodyText(s.room.isEmpty
                         ? String(localized: "That's the air around your sensor right now.", comment: "Onboarding, Apple Home screen: under the first live reading")
                         : String(localized: "That's the air in \(s.room) right now.", comment: "Onboarding, Apple Home screen: under the first live reading; the placeholder is the room name from Apple Home"), ink: true)
            } else {
                BodyText(String(localized: "This sensor doesn't report CO₂, so Kūki will show its other values.", comment: "Onboarding, Apple Home screen: body for a sensor without CO₂"))
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
            let none = String(localized: "No CO₂ reading", comment: "Onboarding, Apple Home screen: sensor list row detail, after the room and home")
            subtitle += subtitle.isEmpty ? none : " · " + none
        } else if let fresh {
            subtitle += " · " + String(localized: "\(Metric.co2.format(fresh)) ppm", comment: "A CO₂ value with its unit, e.g. 812 ppm. Keep ppm.")
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

    private func foundTitle(_ s: SensorInfo) -> String {
        String(localized: "Found \(s.name)", comment: "Onboarding, Apple Home screen: title; the placeholder is the sensor's name, e.g. ALPSTUGA")
    }

    private func lastReportedText(_ s: SensorInfo) -> String {
        guard let heard = recorder.homeKit.snapshots[s.id]?.lastHeard else {
            return String(localized: "Last reported earlier. Apple Home hasn't sent a new reading yet. It often arrives within a minute.",
                          comment: "Onboarding, Apple Home screen: body when the sensor's last value is old and its time is unknown")
        }
        let time = heard.formatted(date: .omitted, time: .shortened)
        return String(localized: "Last reported \(time). Apple Home hasn't sent a new reading yet. It often arrives within a minute.",
                      comment: "Onboarding, Apple Home screen: body when the sensor's last value is old; the placeholder is a time of day, e.g. 14:05")
    }

    // MARK: Changes

    private func stateChanged(_ state: HomeConnectionState) {
        model.reportHome(state, recorder: recorder)
        guard announcedKind != state.kind else { return }
        announcedKind = state.kind
        let text: String?
        switch state {
        case .waiting:
            text = String(localized: "Looking for Apple Home.", comment: "Onboarding, Apple Home screen: VoiceOver announcement")
        case .slow:
            text = String(localized: "Apple Home is taking its time.", comment: "Onboarding, Apple Home screen: VoiceOver announcement")
        case .found(let s, let ppm, true):
            let found = s.room.isEmpty
                ? String(localized: "Found \(s.name).", comment: "Onboarding, Apple Home screen: VoiceOver announcement; the placeholder is the sensor's name")
                : String(localized: "Found \(s.name) in \(s.room).", comment: "Onboarding, Apple Home screen: VoiceOver announcement; the placeholders are the sensor's name and its room in Apple Home")
            text = ppm.map {
                String(localized: "\(found) \(Metric.co2.spoken($0)), \(CO2Level(ppm: $0).title).",
                       comment: "Onboarding, Apple Home screen: VoiceOver announcement: the Found sentence, then the spoken CO₂ reading and the air level name")
            } ?? found
            revealMotes()
        case .noSensor:
            text = String(localized: "No air sensor found in Apple Home.", comment: "Onboarding, Apple Home screen: VoiceOver announcement")
        case .denied:
            text = String(localized: "Kūki can't see Apple Home.", comment: "Onboarding, Apple Home screen: VoiceOver announcement")
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
        let demo = model.offersDemo(recorder)
            ? [OnboardingAction(title: String(localized: "Try the demo", comment: "Onboarding, Apple Home screen: text button; the demo is a simulated sensor (keep short)"), run: tryDemo)] : []
        let check = OnboardingAction(title: String(localized: "Check again", comment: "Onboarding, Apple Home screen: button that asks Apple Home again (keep short)")) { model.checkAgain(recorder) }
        let doneTitle = model.mode == .sheet
            ? String(localized: "Done", comment: "Connect Apple Home sheet: primary button that closes the sheet (keep short)")
            : String(localized: "Continue", comment: "Onboarding: primary button to the next screen (keep short)")
        let home = URL(string: "com.apple.home://")!
        let openHome = OnboardingAction(title: String(localized: "Open Home app", comment: "Onboarding, Apple Home screen: button that opens Apple's Home app (keep short)")) {
            openURL(home) { accepted in if !accepted { model.homeAppFailed = true } }
        }
        switch state {
        case .notRequested:
            return (OnboardingAction(title: String(localized: "Continue", comment: "Onboarding: primary button to the next screen (keep short)")) { model.connect(recorder) }, [])
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
            return (OnboardingAction(title: String(localized: "Continue", comment: "Onboarding: primary button to the next screen (keep short)")) {
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
                let add = OnboardingAction(title: String(localized: "Add Accessory…", comment: "Onboarding, Apple Home screen: button that opens the system's add-accessory sheet; match the Home app's wording (keep short)")) {
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
                return (OnboardingAction(title: String(localized: "Open Settings", comment: "Onboarding, Apple Home screen: button that opens the system Settings app (keep short)")) { openURL(settings) }, demo)
            }
            #endif
            return (nil, demo)
        }
    }
}

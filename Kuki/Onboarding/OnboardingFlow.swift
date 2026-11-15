import Accessibility
import Combine
import SwiftData
import SwiftUI

/// The first-run introduction (and its replay from Settings): a step
/// container with a fixed top bar (Back · progress · Skip), the page, and a
/// pinned bottom bar with the one primary action.
struct OnboardingFlow: View {
    enum Mode { case firstRun, replay }
    let mode: Mode

    @Environment(Recorder.self) private var recorder
    @Environment(AppNav.self) private var nav
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection

    @State private var model: OnboardingModel?
    @State private var viewport = CGSize(width: 390, height: 700)
    @State private var contentUnderBar = false
    /// While typing (the new room's name), the field gets the room the bar
    /// would take; Return or Add confirms it.
    @State private var keyboardUp = false

    private let platform = OnboardingPlatform.current

    var body: some View {
        Group {
            if let model {
                flow(model)
            } else {
                Ink.paper
            }
        }
        .paperBackground()
        .onAppear {
            if model == nil {
                model = OnboardingModel(mode: mode == .replay ? .replay : .firstRun, recorder: recorder)
                OnboardingAnalytics.started(replay: mode == .replay, platform: platform)
            }
        }
    }

    private func flow(_ model: OnboardingModel) -> some View {
        let actions = actions(model)
        let ax = dynamicTypeSize.isAccessibilitySize
        return VStack(spacing: 0) {
            OnboardingTopBar(model: model, showBack: showsBack(model), showSkip: showsSkip(model),
                             skipTitle: mode == .replay
                                ? String(localized: "Close", comment: "Onboarding replay, top bar: closes the introduction without saving (keep short)")
                                : String(localized: "Skip", comment: "Onboarding, top bar: finishes the introduction now (keep short)"),
                             escapeSkips: mode == .replay,
                             back: { model.back(reduceMotion: reduceMotion) },
                             skip: { skip(model) })
            ZStack {
                page(model, secondary: ax ? actions.secondary : [])
                    .id(model.step)
                    .transition(transition(forward: model.forward))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardUp {
                OnboardingBottomBar(primary: actions.primary, secondary: ax ? [] : actions.secondary,
                                    primaryOpacity: model.primaryOpacity, showRule: contentUnderBar, step: model.step)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardUp = false
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        .environment(\.onboardingViewport, viewport)
        #if !targetEnvironment(macCatalyst)
        // Edge swipe for Back: a thin strip on the leading edge, so the gesture
        // never sits over the page's own buttons, sliders and scrolling.
        .overlay(alignment: .leading) {
            if showsBack(model) {
                Color.clear
                    .frame(width: 16)
                    .contentShape(Rectangle())
                    .gesture(edgeSwipe(model))
                    .accessibilityHidden(true)
            }
        }
        #endif
        .onChange(of: model.step, initial: true) { _, step in
            OnboardingAnalytics.stepViewed(step, index: model.index, total: model.path.count)
            if mode == .firstRun { UserDefaults.standard.set(step.rawValue, forKey: OnboardingKeys.resumeStep) }
            if step == .appleHome { model.enterAppleHome(recorder) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from the Home app or Settings: look again.
            if phase == .active, model.step == .appleHome, recorder.homeKit.isStarted { recorder.homeKit.recheck() }
        }
        .task(id: model.step) {
            // The Apple Home clocks (slow, empty hold, reading grace).
            guard model.step == .appleHome else { return }
            while !Task.isCancelled {
                model.clock = .now
                model.noteFound(recorder)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Page

    private func page(_ model: OnboardingModel, secondary: [OnboardingAction]) -> some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: OnboardingMetrics.block) {
                    screen(model)
                    if !secondary.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(secondary) { a in TextLinkButton(title: a.title, action: a.run) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, OnboardingMetrics.side(wide: geo.size.width >= OnboardingMetrics.wideBreakpoint))
                .padding(.vertical, 20)
                // The welcome sits in the middle; every other page starts at
                // the top, so titles don't jump from screen to screen.
                .frame(maxWidth: .infinity, minHeight: geo.size.height,
                       alignment: model.step == .welcome ? .center : .top)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentSize.height - g.contentOffset.y - g.containerSize.height > 1
            } action: { _, under in
                contentUnderBar = under
            }
        }
    }

    @ViewBuilder
    private func screen(_ model: OnboardingModel) -> some View {
        switch model.step {
        case .welcome: WelcomeScreen(model: model)
        case .questions: QuestionsScreen(model: model)
        case .breath: BreathScreen(model: model)
        case .night: NightScreen(model: model)
        case .listen: ListenScreen(platform: platform)
        case .appleHome: AppleHomeScreen(model: model, platform: platform)
        case .place: PlaceScreen(model: model)
        case .furin: FurinScreen(model: model, platform: platform)
        case .plan: PlanScreen(model: model, platform: platform)
        }
    }

    private func transition(forward: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        let sign: CGFloat = (forward ? 1 : -1) * (layoutDirection == .rightToLeft ? -1 : 1)
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: 24 * sign)),
                           removal: .opacity.combined(with: .offset(x: -24 * sign)))
    }

    private func edgeSwipe(_ model: OnboardingModel) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                let toward = layoutDirection == .rightToLeft ? -value.translation.width : value.translation.width
                if toward > 60, abs(value.translation.height) < 80, showsBack(model) {
                    model.back(reduceMotion: reduceMotion)
                }
            }
    }

    // MARK: Chrome rules

    private func isPrimer(_ model: OnboardingModel) -> Bool {
        model.step == .appleHome && model.homeState(recorder) == .notRequested
    }

    /// While the system prompt is up (or about to be), nothing else to tap.
    private func promptUp(_ model: OnboardingModel) -> Bool {
        model.step == .appleHome && model.homeState(recorder) == .waiting
            && (model.awaitingPrompt || scenePhase != .active)
    }

    private func showsBack(_ model: OnboardingModel) -> Bool {
        model.index > 0 && !isPrimer(model) && !promptUp(model)
    }

    private func showsSkip(_ model: OnboardingModel) -> Bool {
        model.step != .plan && !isPrimer(model) && !promptUp(model)
    }

    // MARK: Actions

    private func actions(_ model: OnboardingModel) -> (primary: OnboardingAction?, secondary: [OnboardingAction]) {
        let next = { model.next(reduceMotion: reduceMotion) }
        switch model.step {
        case .welcome:
            return (OnboardingAction(title: String(localized: "Begin", comment: "Onboarding, Welcome screen: primary button that starts the introduction (keep short)"), run: next), [])
        case .questions, .breath, .place, .furin:
            return (OnboardingAction(title: String(localized: "Continue", comment: "Onboarding: primary button to the next screen (keep short)"), run: next), [])
        case .night:
            return (OnboardingAction(title: model.nightPrimaryTitle) { model.nightPrimary(reduceMotion: reduceMotion) }, [])
        case .listen:
            let connected = recorder.homeKitRequested && !recorder.useDemo
            let primary = OnboardingAction(title: mode == .replay && connected
                ? String(localized: "Continue", comment: "Onboarding: primary button to the next screen (keep short)")
                : String(localized: "Connect Apple Home", comment: "Onboarding, Listen screen: primary button (keep short)")) {
                model.demo = false
                model.next(reduceMotion: reduceMotion)
            }
            // A replay that's already on Apple Home offers no way into the demo.
            guard model.offersDemo(recorder) else { return (primary, []) }
            let demoTitle = mode == .replay && recorder.useDemo
                ? String(localized: "Continue with the demo", comment: "Onboarding replay, Listen screen: text button; the demo is a simulated sensor")
                : String(localized: "No sensor yet? Try the demo", comment: "Onboarding, Listen screen: text button; the demo is a simulated sensor")
            return (primary, [OnboardingAction(title: demoTitle) { model.tryDemo(recorder, reduceMotion: reduceMotion) }])
        case .appleHome:
            return AppleHomeActions.actions(
                model.homeState(recorder), model: model, recorder: recorder, platform: platform, openURL: openURL,
                done: {
                    if let s = model.homeState(recorder).sensor { recorder.selectedSensorID = s.id }
                    model.next(reduceMotion: reduceMotion)
                },
                tryDemo: { model.tryDemo(recorder, reduceMotion: reduceMotion) })
        case .plan:
            return (OnboardingAction(title: String(localized: "Begin", comment: "Onboarding, Plan screen: final button that finishes the introduction (keep short)")) {
                finish(model, commit: true)
                OnboardingAnalytics.completed(
                    answers: model.draft.answers, demo: recorder.useDemo,
                    seconds: Int(Date.now.timeIntervalSince(model.startedAt).rounded()),
                    limit: recorder.co2Limit, reminderOn: recorder.reminders.isOn,
                    notificationsOn: recorder.notifyOn)
            }, [])
        }
    }

    private func skip(_ model: OnboardingModel) {
        OnboardingAnalytics.skipped(model.step, index: model.index)
        finish(model, commit: mode == .firstRun)
    }

    /// Begin, or Skip ("finish the introduction now"): the answers given so
    /// far are written, and the app takes over. Replay's Close writes nothing.
    private func finish(_ model: OnboardingModel, commit: Bool) {
        if commit {
            model.commit(recorder: recorder, context: modelContext)
        }
        if mode == .replay {
            withAnimation(.easeInOut(duration: reduceMotion ? 0.25 : 0.5)) { nav.replayingOnboarding = false }
        }
    }
}

// MARK: - Bars

/// ‹ Back · ▬ ▬ ▭ ▭ · Skip — inside the safe area, so on the Duo's outer
/// display Skip stays clear of the status column.
private struct OnboardingTopBar: View {
    let model: OnboardingModel
    let showBack: Bool
    let showSkip: Bool
    let skipTitle: String
    /// Esc is Close in the replay (harmless: it writes nothing); in the first
    /// run Skip commits, so a stray Esc mustn't press it.
    let escapeSkips: Bool
    let back: () -> Void
    let skip: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack {
            ProgressDashes(count: model.path.count, current: model.index)
            HStack {
                Button(action: back) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward").font(.body.weight(.medium))
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text("Back", comment: "Onboarding, top bar: goes to the previous screen (keep short)")
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Ink.inkSoft)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut("[", modifiers: .command)
                .opacity(showBack ? 1 : 0)
                .disabled(!showBack)
                .accessibilityHidden(!showBack)
                .accessibilityLabel(Text("Back", comment: "Onboarding, top bar: goes to the previous screen (keep short)"))
                .accessibilitySortPriority(-1)
                Spacer()
                Button(action: skip) {
                    Text(skipTitle)
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(Ink.inkSoft)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut(escapeSkips ? .cancelAction : nil)
                .opacity(showSkip ? 1 : 0)
                .disabled(!showSkip)
                .accessibilityHidden(!showSkip)
                .accessibilitySortPriority(-2)
            }
            .animation(.easeInOut(duration: 0.2), value: showBack)
            .animation(.easeInOut(duration: 0.2), value: showSkip)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .padding(.top, 4)
    }
}

/// Brush-stroke progress: done dashes in ink, the current one drawn in.
private struct ProgressDashes: View {
    let count: Int
    let current: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Text("\(current + 1) of \(count)", comment: "Onboarding progress at large text sizes: current step of total steps").kukiLabel()
            } else {
                let gap: CGFloat = 6
                let width = min(22, (200 - gap * CGFloat(count - 1)) / CGFloat(count))
                HStack(spacing: gap) {
                    ForEach(0..<count, id: \.self) { i in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Ink.hairline)
                            Capsule().fill(Ink.ink)
                                .scaleEffect(x: i < current ? 1 : (i == current ? 1 : 0), y: 1, anchor: .leading)
                                .opacity(i <= current ? 1 : 0)
                        }
                        .frame(width: width, height: 3)
                    }
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: current)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(current + 1) of \(count)", comment: "Onboarding progress, VoiceOver: current step of total steps"))
        .accessibilitySortPriority(10)
    }
}

private struct OnboardingBottomBar: View {
    let primary: OnboardingAction?
    let secondary: [OnboardingAction]
    let primaryOpacity: Double
    let showRule: Bool
    let step: OnboardingStep

    var body: some View {
        VStack(spacing: 0) {
            Hairline().opacity(showRule ? 1 : 0)
            VStack(spacing: 4) {
                if let primary {
                    PrimaryButton(title: primary.title, action: primary.run)
                        .keyboardShortcut(.defaultAction)
                        .opacity(primaryOpacity)
                        .id(primary.title)
                        .transition(.opacity)
                }
                if !secondary.isEmpty {
                    let row = secondary.count > 1
                        ? AnyLayout(HStackLayout(spacing: 18)) : AnyLayout(VStackLayout(spacing: 0))
                    row {
                        ForEach(secondary) { a in TextLinkButton(title: a.title, action: a.run) }
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: primary?.title)
            .animation(.easeInOut(duration: 0.2), value: secondary.map(\.title))
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .background(Ink.paper)
    }
}

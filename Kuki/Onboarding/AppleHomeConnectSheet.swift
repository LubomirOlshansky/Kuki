import SwiftUI

/// "Connect Apple Home" from the Now screen (after Skip): the Apple Home
/// screen of the introduction as a sheet — primer, then detection — with Done.
struct AppleHomeConnectSheet: View {
    @Environment(Recorder.self) private var recorder
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var model: OnboardingModel?
    @State private var viewport = CGSize(width: 390, height: 700)

    private let platform = OnboardingPlatform.current

    var body: some View {
        Group {
            if let model { content(model) } else { Ink.paper }
        }
        .paperBackground()
        .onAppear {
            if model == nil {
                let m = OnboardingModel(mode: .sheet, recorder: recorder)
                m.enterAppleHome(recorder)
                model = m
            }
        }
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    private func content(_ model: OnboardingModel) -> some View {
        let state = model.homeState(recorder)
        let actions = AppleHomeActions.actions(
            state, model: model, recorder: recorder, platform: platform, openURL: openURL,
            done: {
                if let s = state.sensor { recorder.selectedSensorID = s.id }
                dismiss()
            },
            tryDemo: {
                recorder.useDemo = true
                dismiss()
            })
        return ScrollView {
            AppleHomeScreen(model: model, platform: platform)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 4) {
                if let primary = actions.primary {
                    PrimaryButton(title: primary.title, action: primary.run).keyboardShortcut(.defaultAction)
                }
                HStack(spacing: 18) {
                    ForEach(actions.secondary) { a in TextLinkButton(title: a.title, action: a.run) }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(Ink.paper)
        }
        .overlay(alignment: .topTrailing) {
            // Not on the primer (one button only), and not while the prompt is up.
            if state != .notRequested && !model.awaitingPrompt {
                Button("Close") { dismiss() }
                    .font(.subheadline)
                    .foregroundStyle(Ink.inkSoft)
                    .frame(minWidth: 44, minHeight: 44)
                    .padding(8)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        .environment(\.onboardingViewport, viewport)
        .task {
            while !Task.isCancelled {
                model.clock = .now
                model.noteFound(recorder)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

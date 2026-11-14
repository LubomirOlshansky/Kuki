import os
import SwiftUI
import UIKit

/// Scene ids for the app's windows.
enum WindowID {
    static let main = "main"
    static let settings = "settings"
}

/// Brings a window forward — or opens it again when it was closed. Shared by
/// the Air menu, the ⌘, command and the menu bar item, so none of them does
/// nothing just because the user closed the window.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    /// Captured from the environment by the first window, for callers that
    /// have none of their own (the menu bar bridge).
    var openWindow: OpenWindowAction?

    private struct WeakScene { weak var scene: UIWindowScene? }
    private var scenes: [String: WeakScene] = [:]
    private let log = Logger(subsystem: "com.olshanskysoft.kuki", category: "Windows")

    func register(_ scene: UIWindowScene, as id: String) {
        scenes[id] = WeakScene(scene: scene)
    }

    /// Whether a window for `id` is open right now.
    func isOpen(_ id: String) -> Bool {
        guard let scene = scenes[id]?.scene else { return false }
        return scene.activationState != .unattached
    }

    func show(_ id: String, using action: OpenWindowAction? = nil) {
        if let scene = scenes[id]?.scene, scene.activationState != .unattached {
            // On iPhone the one window is already in front.
            guard UIDevice.current.userInterfaceIdiom != .phone else { return }
            let request = UISceneSessionActivationRequest(session: scene.session)
            UIApplication.shared.activateSceneSession(for: request) { [log] error in
                log.error("Couldn't bring the \(id, privacy: .public) window forward: \(error.localizedDescription, privacy: .public)")
            }
        } else if let open = action ?? openWindow {
            open(id: id)
        } else if id == WindowID.main {
            // No SwiftUI action yet: a fresh application session opens the
            // first window group, which is the main window.
            let request = UISceneSessionActivationRequest(role: .windowApplication)
            UIApplication.shared.activateSceneSession(for: request) { [log] error in
                log.error("Couldn't open a window: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Hands the hosting `UIWindowScene` to `onScene` once the view is in a
/// window — how SwiftUI windows get registered with `WindowRouter` and how
/// the Settings window sets its title and fixed size.
struct SceneReader: UIViewRepresentable {
    let onScene: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onScene = onScene
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        uiView.onScene = onScene
    }

    final class ReaderView: UIView {
        var onScene: ((UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { onScene?(scene) }
        }
    }
}
